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

from fastapi_app.api.routes.websocket import connections, get_authenticated_claims
from fastapi_app.core.geo import geography_point
from fastapi_app.core.redis import DRIVER_GEO_INDEX_KEY, driver_state_key, get_redis
from fastapi_app.db.models.driver import DriverProfile
from fastapi_app.db.models.identity import User
from fastapi_app.db.models.ride import Ride, RideRequestRecipient, RideStatusHistory
from fastapi_app.db.session import get_db_session

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
        ride.status = "expired"
        session.add(
            RideStatusHistory(
                ride_id=ride.id,
                status="expired",
                reason="No driver accepted before the search timeout.",
            )
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
    ride.status = "accepted"
    ride.accepted_driver_id = profile.user_id
    ride.accepted_at = now
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
    session.add(RideStatusHistory(ride_id=ride.id, status="accepted", changed_by_user_id=profile.user_id))
    await session.flush()

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
