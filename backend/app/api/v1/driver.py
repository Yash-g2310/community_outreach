"""Authenticated driver availability endpoints backed by PostgreSQL and Redis."""

from __future__ import annotations

import json
from datetime import timezone, datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, Field
from redis.asyncio import Redis
from redis.exceptions import RedisError
from geoalchemy2 import Geometry
from sqlalchemy import cast, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.websocket import connections, get_authenticated_claims
from app.core.geo import geography_point
from app.core.redis import DRIVER_GEO_INDEX_KEY, driver_state_key, get_redis
from app.db.models.driver import DriverProfile
from app.db.models.identity import User
from app.db.models.ride import Ride, RideParticipantLocation, RideRequestRecipient
from app.db.session import get_db_session
from app.services.ride_state import transition_ride

router = APIRouter(prefix="/driver", tags=["driver availability"])


class GoOnlineRequest(BaseModel):
    """Fresh coordinates are required before a driver becomes discoverable."""

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class PickupLocation(BaseModel):
    latitude: float
    longitude: float


class PendingRideRequest(BaseModel):
    """Ride details visible only to a driver selected as a recipient."""

    ride_id: UUID
    pickup: PickupLocation
    pickup_address: str | None
    dropoff_address: str | None
    passenger_count: int


class PendingRideRequestsResponse(BaseModel):
    requests: list[PendingRideRequest]


class AcceptedRideResponse(BaseModel):
    ride_id: UUID
    status: str
    channel: str


class DeclinedRideResponse(BaseModel):
    ride_id: UUID
    response_status: str


def _unavailable_redis_error() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail="Driver availability is temporarily unavailable. Please try again.",
    )


async def _current_driver(
    request: Request, session: AsyncSession, *, lock: bool = False
) -> tuple[User, DriverProfile]:
    claims = await get_authenticated_claims(request, session)
    if "driver" not in claims["roles"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Driver access is required")
    driver_id = UUID(str(claims["sub"]))
    user = await session.get(User, driver_id)
    query = select(DriverProfile).where(DriverProfile.user_id == driver_id)
    if lock:
        query = query.with_for_update()
    profile = await session.scalar(query)
    if user is None or profile is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Driver profile was not found")
    if user.status != "active":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Driver account is not enabled")
    if not profile.vehicle_license_number.strip():
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="An assigned vehicle is required")
    return user, profile


def _response(profile: DriverProfile) -> dict[str, object]:
    return {
        "status": profile.availability_status,
        "vehicle_id": profile.vehicle_license_number,
        "location_updated_at": profile.location_updated_at,
    }


@router.post("/online")
async def go_online(
    payload: GoOnlineRequest,
    request: Request,
    session: AsyncSession = Depends(get_db_session),
) -> dict[str, object]:
    """Mark the caller available and atomically add them to Redis discovery data."""

    _, profile = await _current_driver(request, session, lock=True)
    now = datetime.now(timezone.utc)
    profile.availability_status = "available"
    profile.current_location = geography_point(latitude=payload.latitude, longitude=payload.longitude)
    profile.location_updated_at = now
    await session.flush()

    state_key = driver_state_key(str(profile.user_id))
    state = json.dumps({"status": "available", "vehicle_id": profile.vehicle_license_number})
    try:
        redis: Redis = get_redis()
        async with redis.pipeline(transaction=True) as pipeline:
            pipeline.set(state_key, state)
            pipeline.execute_command(
                "GEOADD", DRIVER_GEO_INDEX_KEY, payload.longitude, payload.latitude, str(profile.user_id)
            )
            await pipeline.execute()
    except (RedisError, RuntimeError):
        await session.rollback()
        raise _unavailable_redis_error() from None

    try:
        await session.commit()
    except Exception:
        await session.rollback()
        try:
            await redis.delete(state_key)
            await redis.zrem(DRIVER_GEO_INDEX_KEY, str(profile.user_id))
        except RedisError:
            pass
        raise
    return _response(profile)


@router.post("/offline")
async def go_offline(
    request: Request, session: AsyncSession = Depends(get_db_session)
) -> dict[str, object]:
    """Remove the caller from availability state and the nearby-driver geo index."""

    _, profile = await _current_driver(request, session, lock=True)
    if profile.availability_status == "busy":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A busy driver cannot go offline until the accepted ride ends.",
        )
    profile.availability_status = "offline"
    await session.flush()

    state_key = driver_state_key(str(profile.user_id))
    try:
        redis: Redis = get_redis()
        async with redis.pipeline(transaction=True) as pipeline:
            pipeline.set(state_key, json.dumps({"status": "offline", "vehicle_id": profile.vehicle_license_number}))
            pipeline.zrem(DRIVER_GEO_INDEX_KEY, str(profile.user_id))
            await pipeline.execute()
    except (RedisError, RuntimeError):
        await session.rollback()
        raise _unavailable_redis_error() from None

    try:
        await session.commit()
    except Exception:
        await session.rollback()
        raise
    return _response(profile)


@router.get("/status")
async def driver_status(
    request: Request, session: AsyncSession = Depends(get_db_session)
) -> dict[str, object]:
    """Read the durable PostgreSQL availability status for the signed-in driver."""

    _, profile = await _current_driver(request, session)
    return _response(profile)


@router.get("/ride-requests/pending", response_model=PendingRideRequestsResponse)
async def pending_ride_requests(
    request: Request, session: AsyncSession = Depends(get_db_session)
) -> PendingRideRequestsResponse:
    """Return only ride requests that were addressed to the signed-in driver."""

    _, profile = await _current_driver(request, session)
    pickup_geometry = cast(Ride.pickup_location, Geometry(geometry_type="POINT", srid=4326))
    result = await session.execute(
        select(
            Ride.id,
            func.ST_Y(pickup_geometry).label("latitude"),
            func.ST_X(pickup_geometry).label("longitude"),
            Ride.pickup_address,
            Ride.dropoff_address,
            Ride.passenger_count,
        )
        .join(RideRequestRecipient, RideRequestRecipient.ride_id == Ride.id)
        .where(
            RideRequestRecipient.driver_id == profile.user_id,
            RideRequestRecipient.response_status == "pending",
            Ride.status == "searching",
        )
        .order_by(RideRequestRecipient.sent_at.asc())
    )
    return PendingRideRequestsResponse(
        requests=[
            PendingRideRequest(
                ride_id=row.id,
                pickup=PickupLocation(latitude=float(row.latitude), longitude=float(row.longitude)),
                pickup_address=row.pickup_address,
                dropoff_address=row.dropoff_address,
                passenger_count=row.passenger_count,
            )
            for row in result
        ]
    )


@router.post("/ride-requests/{ride_id}/accept", response_model=AcceptedRideResponse)
async def accept_ride_request(
    ride_id: UUID,
    request: Request,
    session: AsyncSession = Depends(get_db_session),
) -> AcceptedRideResponse:
    """Atomically let one pending recipient win a ride request."""

    _, profile = await _current_driver(request, session, lock=True)
    now = datetime.now(timezone.utc)
    ride = await session.scalar(select(Ride).where(Ride.id == ride_id).with_for_update())
    if ride is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ride request was not found")
    if ride.status != "searching":
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Ride request is no longer available")

    if ride.search_expires_at is not None and ride.search_expires_at <= now:
        pending_driver_ids = list(
            await session.scalars(
                select(RideRequestRecipient.driver_id).where(
                    RideRequestRecipient.ride_id == ride.id,
                    RideRequestRecipient.response_status == "pending",
                )
            )
        )
        await session.execute(
            update(RideRequestRecipient)
            .where(
                RideRequestRecipient.ride_id == ride.id,
                RideRequestRecipient.response_status == "pending",
            )
            .values(response_status="expired", responded_at=now)
        )
        await transition_ride(
            session,
            ride,
            to_status="expired",
            actor_role="system",
            actor_id=None,
            reason="No driver accepted before the search timeout.",
            now=now,
        )
        await session.commit()
        await connections.send_to_user(ride.rider_id, {"type": "ride_request_expired", "ride_id": str(ride.id)})
        for pending_driver_id in pending_driver_ids:
            await connections.send_to_user(
                pending_driver_id,
                {"type": "ride_request_closed", "ride_id": str(ride.id), "reason": "no_driver_accepted"},
            )
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Ride request has expired")

    recipient = await session.scalar(
        select(RideRequestRecipient)
        .where(RideRequestRecipient.ride_id == ride.id, RideRequestRecipient.driver_id == profile.user_id)
        .with_for_update()
    )
    if recipient is None or recipient.response_status != "pending":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="This ride request was not sent to you")
    if profile.availability_status != "available":
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Driver must be available to accept a ride")

    other_driver_ids = list(
        await session.scalars(
            select(RideRequestRecipient.driver_id).where(
                RideRequestRecipient.ride_id == ride.id,
                RideRequestRecipient.driver_id != profile.user_id,
                RideRequestRecipient.response_status == "pending",
            )
        )
    )
    ride.accepted_driver_id = profile.user_id
    recipient.response_status = "accepted"
    recipient.responded_at = now
    profile.availability_status = "busy"
    await session.execute(
        update(RideRequestRecipient)
        .where(
            RideRequestRecipient.ride_id == ride.id,
            RideRequestRecipient.driver_id != profile.user_id,
            RideRequestRecipient.response_status == "pending",
        )
        .values(response_status="expired", responded_at=now)
    )
    await transition_ride(
        session,
        ride,
        to_status="accepted",
        actor_role="driver",
        actor_id=profile.user_id,
        now=now,
    )
    # The rider receives a usable initial driver pin immediately after accepting,
    # before the driver's next streamed GPS update arrives.
    if profile.current_location is not None:
        session.add(
            RideParticipantLocation(
                ride_id=ride.id,
                participant_role="driver",
                location=profile.current_location,
                captured_at=profile.location_updated_at or now,
                received_at=now,
                sequence=1,
            )
        )
    await session.flush()

    driver_location = None
    location_geometry = cast(DriverProfile.current_location, Geometry(geometry_type="POINT", srid=4326))
    location_row = (
        await session.execute(
            select(
                func.ST_Y(location_geometry).label("latitude"),
                func.ST_X(location_geometry).label("longitude"),
            ).where(DriverProfile.user_id == profile.user_id)
        )
    ).one_or_none()
    if location_row is not None and location_row.latitude is not None and location_row.longitude is not None:
        driver_location = {
            "latitude": float(location_row.latitude),
            "longitude": float(location_row.longitude),
            "timestamp": (profile.location_updated_at or now).isoformat(),
            "sequence": 1,
        }

    state_key = driver_state_key(str(profile.user_id))
    try:
        redis: Redis = get_redis()
        async with redis.pipeline(transaction=True) as pipeline:
            pipeline.set(state_key, json.dumps({"status": "busy", "vehicle_id": profile.vehicle_license_number}))
            pipeline.zrem(DRIVER_GEO_INDEX_KEY, str(profile.user_id))
            await pipeline.execute()
    except (RedisError, RuntimeError):
        await session.rollback()
        raise _unavailable_redis_error() from None

    try:
        await session.commit()
    except Exception:
        await session.rollback()
        raise

    channel = connections.open_ride_channel(
        ride_id=ride.id,
        rider_id=ride.rider_id,
        driver_id=profile.user_id,
    )
    await connections.send_to_ride(
        ride.id,
        {
            "type": "ride_accepted",
            "ride_id": str(ride.id),
            "channel": channel,
            "driver_id": str(profile.user_id),
            "status": ride.status,
            "state_version": ride.state_version,
            "driver_location": driver_location,
        },
    )
    for other_driver_id in other_driver_ids:
        await connections.send_to_user(
            other_driver_id,
            {
                "type": "ride_request_closed",
                "ride_id": str(ride.id),
                "reason": "accepted_by_another_driver",
            },
        )
    return AcceptedRideResponse(ride_id=ride.id, status=ride.status, channel=channel)


@router.post("/ride-requests/{ride_id}/decline", response_model=DeclinedRideResponse)
async def decline_ride_request(
    ride_id: UUID,
    request: Request,
    session: AsyncSession = Depends(get_db_session),
) -> DeclinedRideResponse:
    """Record that the addressed driver declined a still-searching request.

    Declining affects only this driver's recipient row.  The rider's request
    remains available to every other pending nearby driver until one accepts or
    the normal search expiry process closes it.
    """

    _, profile = await _current_driver(request, session, lock=True)
    ride = await session.scalar(select(Ride).where(Ride.id == ride_id).with_for_update())
    if ride is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ride request was not found")

    recipient = await session.scalar(
        select(RideRequestRecipient)
        .where(RideRequestRecipient.ride_id == ride.id, RideRequestRecipient.driver_id == profile.user_id)
        .with_for_update()
    )
    if recipient is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="This ride request was not sent to you")
    if recipient.response_status == "declined":
        return DeclinedRideResponse(ride_id=ride.id, response_status=recipient.response_status)
    if ride.status != "searching" or recipient.response_status != "pending":
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Ride request is no longer available")

    recipient.response_status = "declined"
    recipient.responded_at = datetime.now(timezone.utc)
    await session.commit()
    return DeclinedRideResponse(ride_id=ride.id, response_status=recipient.response_status)
