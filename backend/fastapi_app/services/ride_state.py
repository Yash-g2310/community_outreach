"""Single, auditable state machine for FastAPI rides."""

from __future__ import annotations

from collections.abc import Iterable
from datetime import datetime, timezone
from typing import Literal
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from fastapi_app.db.models.ride import Ride, RideStatusHistory


RideActorRole = Literal["rider", "driver", "system"]
ACTIVE_RIDE_STATUSES = frozenset({"accepted", "arrived", "started"})
TERMINAL_RIDE_STATUSES = frozenset(
    {"cancelled_by_rider", "cancelled_by_driver", "completed", "expired"}
)

_ALLOWED_TRANSITIONS: dict[str, dict[str, frozenset[RideActorRole]]] = {
    "searching": {
        "accepted": frozenset({"driver"}),
        "cancelled_by_rider": frozenset({"rider"}),
        "expired": frozenset({"system"}),
    },
    "accepted": {
        "arrived": frozenset({"driver"}),
        "cancelled_by_rider": frozenset({"rider"}),
        "cancelled_by_driver": frozenset({"driver"}),
    },
    "arrived": {
        "started": frozenset({"driver"}),
        "cancelled_by_rider": frozenset({"rider"}),
        "cancelled_by_driver": frozenset({"driver"}),
    },
    # Cancellation after a ride starts is intentionally retained for safety and
    # operational recovery.  A non-empty reason is enforced by callers.
    "started": {
        "completed": frozenset({"driver"}),
        "cancelled_by_rider": frozenset({"rider"}),
        "cancelled_by_driver": frozenset({"driver"}),
    },
}


class InvalidRideTransition(ValueError):
    """Raised when a user attempts a state change not allowed by the lifecycle."""


def is_active_status(status: str) -> bool:
    return status in ACTIVE_RIDE_STATUSES


def is_terminal_status(status: str) -> bool:
    return status in TERMINAL_RIDE_STATUSES


def allowed_next_statuses(status: str, actor_role: RideActorRole) -> Iterable[str]:
    """Expose valid next statuses for diagnostics and API error messages."""

    return (
        target
        for target, allowed_roles in _ALLOWED_TRANSITIONS.get(status, {}).items()
        if actor_role in allowed_roles
    )


async def transition_ride(
    session: AsyncSession,
    ride: Ride,
    *,
    to_status: str,
    actor_role: RideActorRole,
    actor_id: UUID | None,
    reason: str | None = None,
    now: datetime | None = None,
) -> RideStatusHistory:
    """Apply one validated transition and append its durable audit record.

    Callers must load ``ride`` with ``FOR UPDATE`` before calling this function.
    Status mutations are deliberately kept here so application code cannot update
    a ride without its matching history row and monotonic state version.
    """

    previous_status = ride.status
    valid_actors = _ALLOWED_TRANSITIONS.get(previous_status, {}).get(to_status, frozenset())
    if actor_role not in valid_actors:
        raise InvalidRideTransition(
            f"Cannot change a {previous_status!r} ride to {to_status!r} as {actor_role!r}"
        )
    if to_status.startswith("cancelled") and not reason:
        raise InvalidRideTransition("A cancellation reason is required")

    occurred_at = now or datetime.now(timezone.utc)
    ride.status = to_status
    ride.state_version += 1
    if to_status == "accepted":
        ride.accepted_at = occurred_at
    elif to_status == "arrived":
        ride.arrived_at = occurred_at
    elif to_status == "started":
        ride.started_at = occurred_at
    elif to_status == "completed":
        ride.completed_at = occurred_at
    elif to_status.startswith("cancelled"):
        ride.cancelled_at = occurred_at
        ride.cancellation_reason = reason

    history = RideStatusHistory(
        ride_id=ride.id,
        status=to_status,
        from_status=previous_status,
        state_version=ride.state_version,
        changed_by_user_id=actor_id,
        actor_role=actor_role,
        reason=reason,
    )
    session.add(history)
    return history
