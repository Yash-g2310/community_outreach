"""Authenticated WebSocket entry point for live ride events."""

from __future__ import annotations

from datetime import timezone, datetime, timedelta
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, HTTPException, Request, WebSocket, WebSocketDisconnect, status
from pydantic import BaseModel, Field, model_validator
from redis.exceptions import RedisError
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from fastapi_app.core.config import get_settings
from fastapi_app.core.geo import geography_point
from fastapi_app.core.redis import DRIVER_GEO_INDEX_KEY, get_redis
from fastapi_app.core.security import decode_access_token
from fastapi_app.db.models.driver import DriverProfile
from fastapi_app.db.models.identity import AuthSession, User
from fastapi_app.db.models.ride import Ride
from fastapi_app.db.session import get_session_factory

router = APIRouter(tags=["realtime"])
_last_driver_location_update: dict[UUID, datetime] = {}


class DriverLocationUpdate(BaseModel):
    """The only driver-location message accepted from a live socket."""

    type: Literal["driver_location_update"]
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    timestamp: datetime

    @model_validator(mode="after")
    def require_timezone(self) -> "DriverLocationUpdate":
        if self.timestamp.tzinfo is None:
            raise ValueError("timestamp must include a timezone")
        return self


class ConnectionManager:
    """Routes private ride events to sockets connected to this API worker."""

    def __init__(self) -> None:
        self._connections: dict[UUID, set[WebSocket]] = {}
        self._ride_channels: dict[UUID, set[UUID]] = {}

    def connect(self, user_id: UUID, websocket: WebSocket) -> None:
        self._connections.setdefault(user_id, set()).add(websocket)

    def disconnect(self, user_id: UUID, websocket: WebSocket) -> None:
        sockets = self._connections.get(user_id)
        if sockets is None:
            return
        sockets.discard(websocket)
        if not sockets:
            self._connections.pop(user_id, None)

    async def send_to_user(self, user_id: UUID, event: dict[str, object]) -> None:
        for websocket in list(self._connections.get(user_id, set())):
            try:
                await websocket.send_json(event)
            except (RuntimeError, WebSocketDisconnect):
                self.disconnect(user_id, websocket)

    def open_ride_channel(self, *, ride_id: UUID, rider_id: UUID, driver_id: UUID) -> str:
        """Create the in-memory channel for exactly one accepted rider/driver pair."""

        self._ride_channels[ride_id] = {rider_id, driver_id}
        return f"ride:{ride_id}"

    def close_ride_channel(self, ride_id: UUID) -> None:
        self._ride_channels.pop(ride_id, None)

    async def send_to_ride(self, ride_id: UUID, event: dict[str, object]) -> None:
        for user_id in self._ride_channels.get(ride_id, set()):
            await self.send_to_user(user_id, event)


connections = ConnectionManager()


def _bearer_token(value: str | None) -> str | None:
    if value and value.lower().startswith("bearer "):
        return value[7:].strip()
    return None


async def _validated_claims(token: str, session: AsyncSession) -> dict[str, object]:
    claims = decode_access_token(token)
    auth_session = await session.get(AuthSession, UUID(str(claims["sid"])))
    user = await session.get(User, UUID(str(claims["sub"])))
    if auth_session is None or auth_session.revoked_at is not None or auth_session.expires_at <= datetime.now(timezone.utc) or user is None or user.status != "active":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Session is no longer active")
    return claims


async def get_authenticated_claims(request: Request, session: AsyncSession) -> dict[str, object]:
    """Dependency-style helper shared by HTTP routes needing an authenticated session."""

    token = _bearer_token(request.headers.get("Authorization"))
    if not token:
        raise HTTPException(status_code=401, detail="Bearer access token is required")
    return await _validated_claims(token, session)


async def _process_driver_location_update(
    *, driver_id: UUID, update: DriverLocationUpdate
) -> tuple[str, UUID | None, UUID | None]:
    """Persist a valid update and keep the available-driver index in sync."""

    now = datetime.now(timezone.utc)
    timestamp = update.timestamp.astimezone(timezone.utc)
    if timestamp < now - timedelta(minutes=2) or timestamp > now + timedelta(minutes=1):
        raise ValueError("Location timestamp is stale or too far in the future")

    last_update = _last_driver_location_update.get(driver_id)
    min_interval = timedelta(seconds=get_settings().driver_location_min_interval_seconds)
    if last_update is not None and now - last_update < min_interval:
        raise ValueError("Location updates are arriving too quickly")

    async with get_session_factory()() as session:
        profile = await session.scalar(
            select(DriverProfile).where(DriverProfile.user_id == driver_id).with_for_update()
        )
        if profile is None:
            raise ValueError("Driver profile was not found")
        if profile.availability_status == "offline":
            raise ValueError("Driver is offline")
        if profile.availability_status not in {"available", "busy"}:
            raise ValueError("Driver is not eligible to send location updates")

        profile.current_location = geography_point(latitude=update.latitude, longitude=update.longitude)
        profile.location_updated_at = now
        await session.flush()
        try:
            redis = get_redis()
            if profile.availability_status == "available":
                await redis.execute_command(
                    "GEOADD", DRIVER_GEO_INDEX_KEY, update.longitude, update.latitude, str(driver_id)
                )
            else:
                # Busy drivers must never appear in the nearby available-driver list.
                await redis.zrem(DRIVER_GEO_INDEX_KEY, str(driver_id))
        except (RedisError, RuntimeError):
            await session.rollback()
            raise ValueError("Live availability is temporarily unavailable") from None

        accepted_ride = None
        if profile.availability_status == "busy":
            accepted_ride = await session.scalar(
                select(Ride).where(Ride.accepted_driver_id == driver_id, Ride.status == "accepted")
            )
        await session.commit()

    _last_driver_location_update[driver_id] = now
    if accepted_ride is None:
        return profile.availability_status, None, None
    return profile.availability_status, accepted_ride.id, accepted_ride.rider_id


@router.websocket("/ws/app/")
async def live_events(websocket: WebSocket) -> None:
    """Authenticate before accepting a real-time connection.

    Native clients may use an Authorization header. The query token remains supported
    for Flutter WebSocket compatibility; it should only ever be sent over wss://.
    """

    token = _bearer_token(websocket.headers.get("Authorization")) or websocket.query_params.get("token")
    if not token:
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION, reason="Access token is required")
        return
    try:
        async with get_session_factory()() as session:
            claims = await _validated_claims(token, session)
    except HTTPException:
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION, reason="Invalid or expired access token")
        return

    user_id = UUID(str(claims["sub"]))
    await websocket.accept()
    connections.connect(user_id, websocket)
    async with get_session_factory()() as session:
        active_rides = await session.scalars(
            select(Ride).where(
                Ride.status == "accepted",
                or_(Ride.rider_id == user_id, Ride.accepted_driver_id == user_id),
            )
        )
        for ride in active_rides:
            if ride.accepted_driver_id is not None:
                connections.open_ride_channel(
                    ride_id=ride.id,
                    rider_id=ride.rider_id,
                    driver_id=ride.accepted_driver_id,
                )
    await websocket.send_json({"type": "connection.ready", "user_id": claims["sub"], "roles": claims["roles"]})
    try:
        while True:
            message = await websocket.receive_json()
            if not isinstance(message, dict):
                await websocket.send_json({"type": "error", "detail": "A JSON object is required"})
                continue
            if message.get("type") == "ping":
                await websocket.send_json({"type": "pong"})
                continue
            if message.get("type") != "driver_location_update":
                await websocket.send_json({"type": "error", "detail": "Unsupported message type"})
                continue
            if "driver" not in claims["roles"]:
                await websocket.send_json({"type": "error", "detail": "Driver access is required"})
                continue
            try:
                # Recheck signature expiry and session revocation for each live location write.
                async with get_session_factory()() as session:
                    claims = await _validated_claims(token, session)
                update = DriverLocationUpdate.model_validate(message)
                availability, ride_id, rider_id = await _process_driver_location_update(
                    driver_id=user_id, update=update
                )
            except HTTPException:
                # A session can be revoked while a socket is open; do not keep it alive.
                await websocket.close(code=status.WS_1008_POLICY_VIOLATION, reason="Authentication expired")
                return
            except ValueError:
                await websocket.send_json({"type": "location_update_rejected"})
                continue

            await websocket.send_json(
                {"type": "location_updated", "at": datetime.now(timezone.utc).isoformat(), "status": availability}
            )
            if ride_id is not None and rider_id is not None:
                await connections.send_to_user(
                    rider_id,
                    {
                        "type": "driver_location_updated",
                        "ride_id": str(ride_id),
                        "driver_id": str(driver_id),
                        "latitude": update.latitude,
                        "longitude": update.longitude,
                        "timestamp": update.timestamp.astimezone(timezone.utc).isoformat(),
                    },
                )
    except (WebSocketDisconnect, ValueError):
        pass
    finally:
        connections.disconnect(user_id, websocket)
        _last_driver_location_update.pop(user_id, None)
