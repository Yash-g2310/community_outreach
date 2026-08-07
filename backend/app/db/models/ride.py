"""Ride request, driver-recipient, and status-history tables."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from geoalchemy2 import Geography
from geoalchemy2.elements import WKBElement
from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


class Ride(Base):
    """A ride request and its eventual driver assignment.

    The pickup point is included in the request sent to nearby drivers.
    The API will expose the rider's live details only to the assigned driver.
    """

    __tablename__ = "rides"
    __table_args__ = (
        CheckConstraint(
            "status IN ('searching', 'accepted', 'arrived', 'started', "
            "'cancelled_by_rider', 'cancelled_by_driver', 'completed', 'expired')",
            name="ck_rides_status",
        ),
    )

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    rider_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True)
    accepted_driver_id: Mapped[UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"), index=True)
    pickup_location: Mapped[WKBElement] = mapped_column(
        Geography(geometry_type="POINT", srid=4326, spatial_index=True),
        nullable=False,
    )
    pickup_address: Mapped[str | None] = mapped_column(Text)
    dropoff_location: Mapped[WKBElement | None] = mapped_column(
        Geography(geometry_type="POINT", srid=4326, spatial_index=True)
    )
    dropoff_address: Mapped[str | None] = mapped_column(Text)
    passenger_count: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    search_radius_meters: Mapped[int] = mapped_column(Integer, default=1000, nullable=False)
    status: Mapped[str] = mapped_column(String(30), default="searching", nullable=False, index=True)
    requested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    search_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), index=True)
    accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    arrived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    cancellation_reason: Mapped[str | None] = mapped_column(Text)
    state_version: Mapped[int] = mapped_column(Integer, default=1, nullable=False)

    rider: Mapped["User"] = relationship(back_populates="requested_rides", foreign_keys=[rider_id])
    driver: Mapped["User | None"] = relationship(back_populates="driven_rides", foreign_keys=[accepted_driver_id])
    recipients: Mapped[list["RideRequestRecipient"]] = relationship(back_populates="ride", cascade="all, delete-orphan")
    status_history: Mapped[list["RideStatusHistory"]] = relationship(back_populates="ride", cascade="all, delete-orphan")
    participant_locations: Mapped[list["RideParticipantLocation"]] = relationship(
        back_populates="ride", cascade="all, delete-orphan"
    )


class RideRequestRecipient(Base):
    """One nearby driver's receipt and response to a ride request."""

    __tablename__ = "ride_request_recipients"
    __table_args__ = (
        UniqueConstraint("ride_id", "driver_id", name="uq_ride_request_recipient"),
        CheckConstraint("response_status IN ('pending', 'accepted', 'declined', 'expired')", name="ck_ride_recipients_response"),
    )

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    ride_id: Mapped[UUID] = mapped_column(ForeignKey("rides.id", ondelete="CASCADE"), nullable=False, index=True)
    driver_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    distance_meters: Mapped[int | None] = mapped_column(Integer)
    response_status: Mapped[str] = mapped_column(String(20), default="pending", nullable=False)
    sent_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    viewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    responded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    ride: Mapped[Ride] = relationship(back_populates="recipients")


class RideStatusHistory(Base):
    """Append-only audit trail of each ride state transition."""

    __tablename__ = "ride_status_history"
    __table_args__ = (
        CheckConstraint(
            "status IN ('searching', 'accepted', 'arrived', 'started', "
            "'cancelled_by_rider', 'cancelled_by_driver', 'completed', 'expired')",
            name="ck_ride_status_history_status",
        ),
        CheckConstraint("actor_role IN ('rider', 'driver', 'system')", name="ck_ride_status_history_actor_role"),
        UniqueConstraint("ride_id", "state_version", name="uq_ride_status_history_version"),
    )

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    ride_id: Mapped[UUID] = mapped_column(ForeignKey("rides.id", ondelete="CASCADE"), nullable=False, index=True)
    status: Mapped[str] = mapped_column(String(30), nullable=False)
    from_status: Mapped[str | None] = mapped_column(String(30))
    state_version: Mapped[int] = mapped_column(Integer, nullable=False)
    changed_by_user_id: Mapped[UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    actor_role: Mapped[str] = mapped_column(String(20), nullable=False)
    reason: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    ride: Mapped[Ride] = relationship(back_populates="status_history")


class RideParticipantLocation(Base):
    """The latest shared location for one participant during a ride.

    This deliberately stores only the latest point.  Continuous location history is
    not needed for ride matching and retaining it would unnecessarily increase the
    privacy and storage footprint.
    """

    __tablename__ = "ride_participant_locations"
    __table_args__ = (
        CheckConstraint("participant_role IN ('rider', 'driver')", name="ck_ride_participant_location_role"),
    )

    ride_id: Mapped[UUID] = mapped_column(ForeignKey("rides.id", ondelete="CASCADE"), primary_key=True)
    participant_role: Mapped[str] = mapped_column(String(20), primary_key=True)
    location: Mapped[WKBElement] = mapped_column(
        Geography(geometry_type="POINT", srid=4326, spatial_index=True), nullable=False
    )
    captured_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    sequence: Mapped[int] = mapped_column(Integer, default=1, nullable=False)

    ride: Mapped[Ride] = relationship(back_populates="participant_locations")
