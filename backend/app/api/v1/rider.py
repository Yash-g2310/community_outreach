"""Rider-facing discovery endpoints."""

from __future__ import annotations

import json

from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from pydantic import BaseModel, ConfigDict, Field
from redis.asyncio import Redis
from redis.exceptions import RedisError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.websocket import connections, get_authenticated_claims
from app.core.config import get_settings
from app.core.geo import geography_point
from app.core.redis import DRIVER_GEO_INDEX_KEY, driver_state_key, get_redis
from app.db.models.identity import User
from app.db.models.ride import Ride, RideRequestRecipient, RideStatusHistory
from app.db.session import get_db_session
from app.services.ride_state import transition_ride

router = APIRouter(prefix="/rider", tags=["rider discovery"])


class NearbyDriver(BaseModel):
    """The only driver details a rider needs before requesting a ride."""

    driver_id: str
    latitude: float
    longitude: float


class NearbyDriversResponse(BaseModel):
    drivers: list[NearbyDriver]


class RideRequestCreate(BaseModel):
    """Pickup information sent to every nearby driver with a ride request."""

    model_config = ConfigDict(populate_by_name=True, str_strip_whitespace=True)

    pickup_latitude: float = Field(ge=-90, le=90)
    pickup_longitude: float = Field(ge=-180, le=180)
    pickup_address: str | None = Field(default=None, max_length=1_000)
    dropoff_address: str | None = Field(default=None, max_length=1_000)
    passenger_count: int = Field(default=1, validation_alias="number_of_passengers", ge=1, le=6)


class RideRequestCreated(BaseModel):
    id: UUID
    status: str
    driver_candidates: int
    message: str


def _unavailable_redis_error() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail="Nearby driver discovery is temporarily unavailable. Please try again.",
    )


@router.get("/nearby-drivers", response_model=NearbyDriversResponse)
async def nearby_drivers(
    request: Request,
    latitude: float = Query(..., ge=-90, le=90),
    longitude: float = Query(..., ge=-180, le=180),
    radius_meters: int = Query(1500, ge=100, le=10_000),
    limit: int = Query(20, ge=1, le=50),
    session: AsyncSession = Depends(get_db_session),
) -> NearbyDriversResponse:
    """Return available drivers nearest to the rider's current coordinates.

    Redis is the source of truth for live discoverability.  Driver profile, contact,
    vehicle, and account data are intentionally never returned before a ride is accepted.
    """

    claims = await get_authenticated_claims(request, session)
    if "rider" not in claims["roles"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Rider access is required")

    try:
        redis: Redis = get_redis()
        matches = await redis.execute_command(
            "GEOSEARCH",
            DRIVER_GEO_INDEX_KEY,
            "FROMLONLAT",
            longitude,
            latitude,
            "BYRADIUS",
            radius_meters,
            "m",
            "ASC",
            "COUNT",
            limit,
            "WITHCOORD",
        )
        driver_ids = [str(match[0]) for match in matches]
        states = await redis.mget([driver_state_key(driver_id) for driver_id in driver_ids]) if driver_ids else []
    except (RedisError, RuntimeError):
        raise _unavailable_redis_error() from None

    drivers: list[NearbyDriver] = []
    for match, raw_state in zip(matches, states):
        try:
            state = json.loads(raw_state) if raw_state else {}
            longitude_value, latitude_value = match[1]
        except (IndexError, TypeError, ValueError, json.JSONDecodeError):
            # Ignore stale or malformed ephemeral records rather than exposing them.
            continue
        if state.get("status") != "available":
            continue
        drivers.append(
            NearbyDriver(
                driver_id=str(match[0]),
                latitude=float(latitude_value),
                longitude=float(longitude_value),
            )
        )

    return NearbyDriversResponse(drivers=drivers)


@router.post("/request", response_model=RideRequestCreated, status_code=status.HTTP_201_CREATED)
async def create_ride_request(
    payload: RideRequestCreate,
    request: Request,
    session: AsyncSession = Depends(get_db_session),
) -> RideRequestCreated:
    """Create a ride request and broadcast its pickup point to nearby drivers."""

    claims = await get_authenticated_claims(request, session)
    if "rider" not in claims["roles"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Rider access is required")
    rider_id = UUID(str(claims["sub"]))

    # Lock the rider row so concurrent requests cannot both pass the active-ride check.
    await session.scalar(select(User.id).where(User.id == rider_id).with_for_update())
    active_ride = await session.scalar(
        select(Ride.id).where(Ride.rider_id == rider_id, Ride.status.in_(("searching", "accepted", "arrived", "started")))
    )
    if active_ride is not None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="You already have an active ride request")

    search_radius_meters = get_settings().ride_request_broadcast_radius_meters
    now = datetime.now(timezone.utc)
    search_expires_at = now + timedelta(seconds=get_settings().ride_request_search_timeout_seconds)
    ride = Ride(
        rider_id=rider_id,
        pickup_location=geography_point(latitude=payload.pickup_latitude, longitude=payload.pickup_longitude),
        pickup_address=payload.pickup_address,
        dropoff_address=payload.dropoff_address,
        passenger_count=payload.passenger_count,
        search_radius_meters=search_radius_meters,
        search_expires_at=search_expires_at,
        status="searching",
        state_version=1,
    )
    session.add(ride)
    await session.flush()
    session.add(
        RideStatusHistory(
            ride_id=ride.id,
            status="searching",
            from_status=None,
            state_version=1,
            changed_by_user_id=rider_id,
            actor_role="rider",
        )
    )

    try:
        redis: Redis = get_redis()
        matches = await redis.execute_command(
            "GEOSEARCH",
            DRIVER_GEO_INDEX_KEY,
            "FROMLONLAT",
            payload.pickup_longitude,
            payload.pickup_latitude,
            "BYRADIUS",
            search_radius_meters,
            "m",
            "ASC",
            "COUNT",
            50,
            "WITHDIST",
            "WITHCOORD",
        )
        driver_ids = [str(match[0]) for match in matches]
        states = await redis.mget([driver_state_key(driver_id) for driver_id in driver_ids]) if driver_ids else []
    except (RedisError, RuntimeError):
        await session.rollback()
        raise _unavailable_redis_error() from None

    recipients: list[tuple[UUID, int]] = []
    for match, raw_state in zip(matches, states):
        try:
            state = json.loads(raw_state) if raw_state else {}
            driver_id = UUID(str(match[0]))
            distance_meters = round(float(match[1]) * 1_000)
        except (IndexError, TypeError, ValueError, json.JSONDecodeError):
            continue
        if state.get("status") == "available":
            recipients.append((driver_id, distance_meters))

    session.add_all(
        RideRequestRecipient(
            ride_id=ride.id,
            driver_id=driver_id,
            distance_meters=distance_meters,
            response_status="pending",
            sent_at=now,
        )
        for driver_id, distance_meters in recipients
    )
    if not recipients:
        await transition_ride(
            session,
            ride,
            to_status="expired",
            actor_role="system",
            actor_id=None,
            reason="No available drivers were found at request time.",
            now=now,
        )
    await session.commit()

    event = {
        "type": "ride_request",
        "ride_id": str(ride.id),
        "pickup": {
            "lat": payload.pickup_latitude,
            "lng": payload.pickup_longitude,
        },
        "pickup_address": payload.pickup_address,
        "dropoff_address": payload.dropoff_address,
        "passenger_count": payload.passenger_count,
    }
    for driver_id, _ in recipients:
        await connections.send_to_user(driver_id, event)

    candidate_count = len(recipients)
    return RideRequestCreated(
        id=ride.id,
        status=ride.status,
        driver_candidates=candidate_count,
        message="Ride request sent to nearby drivers." if candidate_count else "No drivers are available nearby.",
    )
