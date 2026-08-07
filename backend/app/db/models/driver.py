"""Driver profile table for the MVP."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from geoalchemy2 import Geography
from geoalchemy2.elements import WKBElement
from sqlalchemy import CheckConstraint, DateTime, ForeignKey, String, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


class DriverProfile(Base):
    """Driver availability, vehicle licence number, and last-known location."""

    __tablename__ = "driver_profiles"
    __table_args__ = (
        CheckConstraint(
            "availability_status IN ('offline', 'available', 'busy')",
            name="ck_driver_profiles_availability",
        ),
    )

    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    vehicle_license_number: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    availability_status: Mapped[str] = mapped_column(String(20), default="offline", nullable=False, index=True)
    current_location: Mapped[WKBElement | None] = mapped_column(
        Geography(geometry_type="POINT", srid=4326, spatial_index=True)
    )
    location_updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
    )

    user: Mapped["User"] = relationship(back_populates="driver_profile")
