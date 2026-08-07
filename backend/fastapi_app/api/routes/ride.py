"""Ride lifecycle, recovery snapshot, and audit endpoints."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, status
from geoalchemy2 import Geometry
from pydantic import BaseModel, Field
from redis.asyncio import Redis
from redis.exceptions import RedisError
from sqlalchemy import cast, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from fastapi_app.api.routes.websocket import connections, get_authenticated_claims
from fastapi_app.core.redis import DRIVER_GEO_INDEX_KEY, driver_state_key, get_redis
from fastapi_app.db.models.driver import DriverProfile
from fastapi_app.db.models.ride import Ride, RideParticipantLocation, RideRequestRecipient, RideStatusHistory
from fastapi_app.db.session import get_db_session
from fastapi_app.services.ride_state import InvalidRideTransition, is_terminal_status, transition_ride


router = APIRouter(prefix="/rides", tags=["ride lifecycle"])


class CancellationRequest(BaseModel):
    reason: str = Field(min_length=1, max_length=1_000)


class RideStateResponse(BaseModel):
    ride_id: UUID
    status: str
    state_version: int
    changed_at: datetime


class SharedLocation(BaseModel):
    participant: str
    latitude: float
    longitude: float
    captured_at: datetime
    sequence: int


class RideSnapshot(BaseModel):
    ride_id: UUID
    status: str
    state_version: int
    accepted_at: datetime | None
    arrived_at: datetime | None
    started_at: datetime | None
    peer_location: SharedLocation | None


class HistoryItem(BaseModel):
    from_status: str | None
    to_status: str
    state_version: int
    actor_role: str
    changed_by_user_id: UUID | None
    reason: str | None
    created_at: datetime


class RideHistoryResponse(BaseModel):
    ride_id: UUID
    transitions: list[HistoryItem]


class RideListItem(BaseModel):
    """Privacy-preserving ride summary for the signed-in participant's history."""

    id: UUID
    status: str
    participant_role: str
    pickup_address: str | None
    dropoff_address: str | None
    passenger_count: int
    requested_at: datetime
    accepted_at: datetime | None
    arrived_at: datetime | None
    started_at: datetime | None
    completed_at: datetime | None
    cancelled_at: datetime | None
    cancellation_reason: str | None


class RideListResponse(BaseModel):
    rides: list[RideListItem]


class ActiveRideResponse(BaseModel):
    """The signed-in participant's one recoverable, non-terminal ride."""

    id: UUID
    status: str
    participant_role: str
    pickup_address: str | None
    dropoff_address: str | None
    passenger_count: int
    pickup_latitude: float
    pickup_longitude: float


async def _claims_for_role(request: Request, session: AsyncSession, role: str) -> dict[str, object]:
    claims = await get_authenticated_claims(request, session)
    if role not in claims["roles"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=f"{role.title()} access is required")
    return claims


async def _driver_profile(session: AsyncSession, driver_id: UUID) -> DriverProfile:
    profile = await session.scalar(
        select(DriverProfile).where(DriverProfile.user_id == driver_id).with_for_update()
    )
    if profile is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Driver profile was not found")
    return profile


async def _restore_driver_availability(session: AsyncSession, profile: DriverProfile) -> None:
    """Return a terminal-ride driver to Redis discovery using their last GPS point."""

    profile.availability_status = "available"
    await session.flush()
    location_geometry = cast(DriverProfile.current_location, Geometry(geometry_type="POINT", srid=4326))
    location = (
        await session.execute(
            select(
                func.ST_Y(location_geometry).label("latitude"),
                func.ST_X(location_geometry).label("longitude"),
            ).where(DriverProfile.user_id == profile.user_id)
        )
    ).one_or_none()
    if location is None or location.latitude is None or location.longitude is None:
        profile.availability_status = "offline"
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Driver location is required before becoming available again",
        )
    try:
        redis: Redis = get_redis()
        async with redis.pipeline(transaction=True) as pipeline:
            pipeline.set(
                driver_state_key(str(profile.user_id)),
                json.dumps({"status": "available", "vehicle_id": profile.vehicle_license_number}),
            )
            pipeline.execute_command(
                "GEOADD",
                DRIVER_GEO_INDEX_KEY,
                float(location.longitude),
                float(location.latitude),
                str(profile.user_id),
            )
            await pipeline.execute()
    except (RedisError, RuntimeError):
        await session.rollback()
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Driver availability is temporarily unavailable. Please try again.",
        ) from None


async def _emit_state_change(ride: Ride, *, previous_status: str, actor_role: str, reason: str | None) -> None:
    event = {
        "type": "ride_state_changed",
        "ride_id": str(ride.id),
        "previous_status": previous_status,
        "status": ride.status,
        "state_version": ride.state_version,
        "actor_role": actor_role,
        "reason": reason,
        "occurred_at": datetime.now(timezone.utc).isoformat(),
    }
    await connections.send_to_user(ride.rider_id, event)
    if ride.accepted_driver_id is not None:
        await connections.send_to_user(ride.accepted_driver_id, event)
    if is_terminal_status(ride.status):
        connections.close_ride_channel(ride.id)


def _transition_error(error: InvalidRideTransition) -> HTTPException:
    return HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error))


async def _driver_action(
    *,
    ride_id: UUID,
    target_status: str,
    reason: str | None,
    request: Request,
    session: AsyncSession,
) -> RideStateResponse:
    claims = await _claims_for_role(request, session, "driver")
    driver_id = UUID(str(claims["sub"]))
    profile = await _driver_profile(session, driver_id)
    ride = await session.scalar(select(Ride).where(Ride.id == ride_id).with_for_update())
    if ride is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ride was not found")
    if ride.accepted_driver_id != driver_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="This ride is not assigned to you")

    previous_status = ride.status
    now = datetime.now(timezone.utc)
    try:
        await transition_ride(
            session,
            ride,
            to_status=target_status,
            actor_role="driver",
            actor_id=driver_id,
            reason=reason,
            now=now,
        )
    except InvalidRideTransition as error:
        raise _transition_error(error) from None
    if is_terminal_status(ride.status):
        await _restore_driver_availability(session, profile)
    await session.commit()
    await _emit_state_change(ride, previous_status=previous_status, actor_role="driver", reason=reason)
    return RideStateResponse(ride_id=ride.id, status=ride.status, state_version=ride.state_version, changed_at=now)


@router.get("/history", response_model=RideListResponse)
async def ride_list_history(
    request: Request, session: AsyncSession = Depends(get_db_session)
) -> RideListResponse:
    """List completed or terminal rides visible to the signed-in rider or driver.

    The endpoint deliberately excludes the other participant's contact and profile
    details.  A ride only needs its own lifecycle and address summary here.
    """

    claims = await get_authenticated_claims(request, session)
    user_id = UUID(str(claims["sub"]))
    terminal_statuses = (
        "completed",
        "cancelled_by_rider",
        "cancelled_by_driver",
        "expired",
    )
    rides = list(
        await session.scalars(
            select(Ride)
            .where(
                Ride.status.in_(terminal_statuses),
                or_(Ride.rider_id == user_id, Ride.accepted_driver_id == user_id),
            )
            .order_by(Ride.requested_at.desc())
        )
    )
    return RideListResponse(
        rides=[
            RideListItem(
                id=ride.id,
                status=ride.status,
                participant_role="rider" if ride.rider_id == user_id else "driver",
                pickup_address=ride.pickup_address,
                dropoff_address=ride.dropoff_address,
                passenger_count=ride.passenger_count,
                requested_at=ride.requested_at,
                accepted_at=ride.accepted_at,
                arrived_at=ride.arrived_at,
                started_at=ride.started_at,
                completed_at=ride.completed_at,
                cancelled_at=ride.cancelled_at,
                cancellation_reason=ride.cancellation_reason,
            )
            for ride in rides
        ]
    )


@router.get("/active", response_model=ActiveRideResponse | None)
async def active_ride(
    request: Request, session: AsyncSession = Depends(get_db_session)
) -> ActiveRideResponse | None:
    """Return the caller's current ride so an app restart can resume it.

    A rider may resume a searching request; a driver only sees a ride after it
    has been accepted by that driver.  No participant profile or contact data is
    exposed here.
    """

    claims = await get_authenticated_claims(request, session)
    user_id = UUID(str(claims["sub"]))
    location_geometry = cast(Ride.pickup_location, Geometry(geometry_type="POINT", srid=4326))
    row = (
        await session.execute(
            select(
                Ride,
                func.ST_Y(location_geometry).label("pickup_latitude"),
                func.ST_X(location_geometry).label("pickup_longitude"),
            )
            .where(
                Ride.status.in_(("searching", "accepted", "arrived", "started")),
                or_(Ride.rider_id == user_id, Ride.accepted_driver_id == user_id),
            )
            .order_by(Ride.requested_at.desc())
            .limit(1)
        )
    ).one_or_none()
    if row is None:
        return None
    ride = row[0]
    return ActiveRideResponse(
        id=ride.id,
        status=ride.status,
        participant_role="rider" if ride.rider_id == user_id else "driver",
        pickup_address=ride.pickup_address,
        dropoff_address=ride.dropoff_address,
        passenger_count=ride.passenger_count,
        pickup_latitude=float(row.pickup_latitude),
        pickup_longitude=float(row.pickup_longitude),
    )


@router.post("/{ride_id}/arrive", response_model=RideStateResponse)
async def arrive_at_pickup(
    ride_id: UUID, request: Request, session: AsyncSession = Depends(get_db_session)
) -> RideStateResponse:
    return await _driver_action(
        ride_id=ride_id, target_status="arrived", reason=None, request=request, session=session
    )


@router.post("/{ride_id}/start", response_model=RideStateResponse)
async def start_ride(
    ride_id: UUID, request: Request, session: AsyncSession = Depends(get_db_session)
) -> RideStateResponse:
    return await _driver_action(
        ride_id=ride_id, target_status="started", reason=None, request=request, session=session
    )


@router.post("/{ride_id}/complete", response_model=RideStateResponse)
async def complete_ride(
    ride_id: UUID, request: Request, session: AsyncSession = Depends(get_db_session)
) -> RideStateResponse:
    return await _driver_action(
        ride_id=ride_id, target_status="completed", reason=None, request=request, session=session
    )


@router.post("/{ride_id}/driver-cancel", response_model=RideStateResponse)
async def driver_cancel_ride(
    ride_id: UUID,
    payload: CancellationRequest,
    request: Request,
    session: AsyncSession = Depends(get_db_session),
) -> RideStateResponse:
    return await _driver_action(
        ride_id=ride_id,
        target_status="cancelled_by_driver",
        reason=payload.reason,
        request=request,
        session=session,
    )


@router.post("/{ride_id}/rider-cancel", response_model=RideStateResponse)
async def rider_cancel_ride(
    ride_id: UUID,
    payload: CancellationRequest,
    request: Request,
    session: AsyncSession = Depends(get_db_session),
) -> RideStateResponse:
    claims = await _claims_for_role(request, session, "rider")
    rider_id = UUID(str(claims["sub"]))
    ride = await session.scalar(select(Ride).where(Ride.id == ride_id).with_for_update())
    if ride is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ride was not found")
    if ride.rider_id != rider_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="This ride does not belong to you")

    previous_status = ride.status
    now = datetime.now(timezone.utc)
    pending_driver_ids: list[UUID] = []
    if previous_status == "searching":
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
    try:
        await transition_ride(
            session,
            ride,
            to_status="cancelled_by_rider",
            actor_role="rider",
            actor_id=rider_id,
            reason=payload.reason,
            now=now,
        )
    except InvalidRideTransition as error:
        raise _transition_error(error) from None
    if ride.accepted_driver_id is not None:
        await _restore_driver_availability(session, await _driver_profile(session, ride.accepted_driver_id))
    await session.commit()
    await _emit_state_change(ride, previous_status=previous_status, actor_role="rider", reason=payload.reason)
    for driver_id in pending_driver_ids:
        await connections.send_to_user(
            driver_id,
            {"type": "ride_request_closed", "ride_id": str(ride.id), "reason": "cancelled_by_rider"},
        )
    return RideStateResponse(ride_id=ride.id, status=ride.status, state_version=ride.state_version, changed_at=now)


@router.get("/{ride_id}/snapshot", response_model=RideSnapshot)
async def ride_snapshot(
    ride_id: UUID, request: Request, session: AsyncSession = Depends(get_db_session)
) -> RideSnapshot:
    claims = await get_authenticated_claims(request, session)
    user_id = UUID(str(claims["sub"]))
    ride = await session.get(Ride, ride_id)
    if ride is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ride was not found")
    if user_id == ride.rider_id:
        peer_role = "driver"
    elif user_id == ride.accepted_driver_id:
        peer_role = "rider"
    else:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="This ride is not visible to you")

    peer_location: SharedLocation | None = None
    if not is_terminal_status(ride.status):
        location_geometry = cast(RideParticipantLocation.location, Geometry(geometry_type="POINT", srid=4326))
        row = (
            await session.execute(
                select(
                    RideParticipantLocation.participant_role,
                    func.ST_Y(location_geometry).label("latitude"),
                    func.ST_X(location_geometry).label("longitude"),
                    RideParticipantLocation.captured_at,
                    RideParticipantLocation.sequence,
                ).where(
                    RideParticipantLocation.ride_id == ride.id,
                    RideParticipantLocation.participant_role == peer_role,
                )
            )
        ).one_or_none()
        if row is not None:
            peer_location = SharedLocation(
                participant=row.participant_role,
                latitude=float(row.latitude),
                longitude=float(row.longitude),
                captured_at=row.captured_at,
                sequence=row.sequence,
            )
    return RideSnapshot(
        ride_id=ride.id,
        status=ride.status,
        state_version=ride.state_version,
        accepted_at=ride.accepted_at,
        arrived_at=ride.arrived_at,
        started_at=ride.started_at,
        peer_location=peer_location,
    )


@router.get("/{ride_id}/history", response_model=RideHistoryResponse)
async def ride_history(
    ride_id: UUID, request: Request, session: AsyncSession = Depends(get_db_session)
) -> RideHistoryResponse:
    claims = await get_authenticated_claims(request, session)
    user_id = UUID(str(claims["sub"]))
    ride = await session.get(Ride, ride_id)
    if ride is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ride was not found")
    if user_id not in {ride.rider_id, ride.accepted_driver_id}:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="This ride is not visible to you")
    rows = await session.scalars(
        select(RideStatusHistory)
        .where(RideStatusHistory.ride_id == ride.id)
        .order_by(RideStatusHistory.state_version.asc())
    )
    return RideHistoryResponse(
        ride_id=ride.id,
        transitions=[
            HistoryItem(
                from_status=row.from_status,
                to_status=row.status,
                state_version=row.state_version,
                actor_role=row.actor_role,
                changed_by_user_id=row.changed_by_user_id,
                reason=row.reason,
                created_at=row.created_at,
            )
            for row in rows
        ],
    )
