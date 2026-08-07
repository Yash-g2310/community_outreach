"""Expire ride searches that no driver accepted before their deadline."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from uuid import UUID

from sqlalchemy import select, update

from fastapi_app.db.models.ride import Ride, RideRequestRecipient
from fastapi_app.db.session import get_session_factory
from fastapi_app.services.ride_state import transition_ride


@dataclass(frozen=True)
class ExpiredRide:
    ride_id: UUID
    rider_id: UUID
    driver_ids: list[UUID]


async def expire_due_ride_requests() -> list[ExpiredRide]:
    """Atomically expire overdue searches and their unanswered recipient rows."""

    now = datetime.now(timezone.utc)
    expired: list[ExpiredRide] = []
    async with get_session_factory()() as session:
        rides = list(
            await session.scalars(
                select(Ride)
                .where(Ride.status == "searching", Ride.search_expires_at <= now)
                .with_for_update(skip_locked=True)
            )
        )
        for ride in rides:
            driver_ids = list(
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
            expired.append(ExpiredRide(ride_id=ride.id, rider_id=ride.rider_id, driver_ids=driver_ids))
        await session.commit()
    return expired
