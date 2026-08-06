"""Create the FastAPI ride-service schema."""

from typing import Sequence, Union

from alembic import op
import geoalchemy2
import sqlalchemy as sa


revision: str = "20260804_01"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS postgis")

    op.create_table(
        "users",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("phone", sa.String(length=20), nullable=False),
        sa.Column("email", sa.String(length=320), nullable=True),
        sa.Column("first_name", sa.String(length=100), nullable=False),
        sa.Column("last_name", sa.String(length=100), nullable=True),
        sa.Column("profile_image_key", sa.Text(), nullable=True),
        sa.Column("status", sa.String(length=30), nullable=False),
        sa.Column("phone_verified_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("email"),
        sa.UniqueConstraint("phone"),
    )
    op.create_table(
        "user_roles",
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("role", sa.String(length=20), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.CheckConstraint("role IN ('rider', 'driver')", name="ck_user_roles_role"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("user_id", "role"),
    )
    op.create_table(
        "user_devices",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("device_identifier", sa.String(length=255), nullable=False),
        sa.Column("platform", sa.String(length=20), nullable=False),
        sa.Column("push_token", sa.Text(), nullable=True),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.CheckConstraint("platform IN ('android', 'ios', 'web')", name="ck_user_devices_platform"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", "device_identifier", name="uq_user_device_identifier"),
    )
    op.create_index("ix_user_devices_user_id", "user_devices", ["user_id"], unique=False)
    op.create_table(
        "auth_sessions",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("device_id", sa.UUID(), nullable=True),
        sa.Column("refresh_token_hash", sa.String(length=255), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["device_id"], ["user_devices.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("refresh_token_hash"),
    )
    op.create_index("ix_auth_sessions_user_id", "auth_sessions", ["user_id"], unique=False)
    op.create_table(
        "driver_profiles",
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("vehicle_license_number", sa.String(length=50), nullable=False),
        sa.Column("availability_status", sa.String(length=20), nullable=False),
        sa.Column("current_location", geoalchemy2.Geography(geometry_type="POINT", srid=4326, spatial_index=False), nullable=True),
        sa.Column("location_updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.CheckConstraint("availability_status IN ('offline', 'available', 'busy')", name="ck_driver_profiles_availability"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("user_id"),
        sa.UniqueConstraint("vehicle_license_number"),
    )
    op.create_index("ix_driver_profiles_availability_status", "driver_profiles", ["availability_status"], unique=False)
    op.create_index("idx_driver_profiles_current_location", "driver_profiles", ["current_location"], unique=False, postgresql_using="gist")
    op.create_table(
        "rides",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("rider_id", sa.UUID(), nullable=False),
        sa.Column("accepted_driver_id", sa.UUID(), nullable=True),
        sa.Column("pickup_location", geoalchemy2.Geography(geometry_type="POINT", srid=4326, spatial_index=False), nullable=False),
        sa.Column("pickup_address", sa.Text(), nullable=True),
        sa.Column("dropoff_location", geoalchemy2.Geography(geometry_type="POINT", srid=4326, spatial_index=False), nullable=True),
        sa.Column("dropoff_address", sa.Text(), nullable=True),
        sa.Column("passenger_count", sa.Integer(), nullable=False),
        sa.Column("search_radius_meters", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(length=30), nullable=False),
        sa.Column("requested_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("cancelled_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("cancellation_reason", sa.Text(), nullable=True),
        sa.CheckConstraint("status IN ('requested', 'accepted', 'cancelled_by_rider', 'cancelled_by_driver', 'completed', 'expired')", name="ck_rides_status"),
        sa.ForeignKeyConstraint(["accepted_driver_id"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["rider_id"], ["users.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_rides_accepted_driver_id", "rides", ["accepted_driver_id"], unique=False)
    op.create_index("ix_rides_rider_id", "rides", ["rider_id"], unique=False)
    op.create_index("ix_rides_status", "rides", ["status"], unique=False)
    op.create_index("idx_rides_pickup_location", "rides", ["pickup_location"], unique=False, postgresql_using="gist")
    op.create_index("idx_rides_dropoff_location", "rides", ["dropoff_location"], unique=False, postgresql_using="gist")
    op.create_table(
        "ride_request_recipients",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("ride_id", sa.UUID(), nullable=False),
        sa.Column("driver_id", sa.UUID(), nullable=False),
        sa.Column("distance_meters", sa.Integer(), nullable=True),
        sa.Column("response_status", sa.String(length=20), nullable=False),
        sa.Column("sent_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("viewed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("responded_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("response_status IN ('pending', 'accepted', 'declined', 'expired')", name="ck_ride_recipients_response"),
        sa.ForeignKeyConstraint(["driver_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["ride_id"], ["rides.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("ride_id", "driver_id", name="uq_ride_request_recipient"),
    )
    op.create_index("ix_ride_request_recipients_driver_id", "ride_request_recipients", ["driver_id"], unique=False)
    op.create_index("ix_ride_request_recipients_ride_id", "ride_request_recipients", ["ride_id"], unique=False)
    op.create_table(
        "ride_status_history",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("ride_id", sa.UUID(), nullable=False),
        sa.Column("status", sa.String(length=30), nullable=False),
        sa.Column("changed_by_user_id", sa.UUID(), nullable=True),
        sa.Column("reason", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.CheckConstraint("status IN ('requested', 'accepted', 'cancelled_by_rider', 'cancelled_by_driver', 'completed', 'expired')", name="ck_ride_status_history_status"),
        sa.ForeignKeyConstraint(["changed_by_user_id"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["ride_id"], ["rides.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_ride_status_history_ride_id", "ride_status_history", ["ride_id"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_ride_status_history_ride_id", table_name="ride_status_history")
    op.drop_table("ride_status_history")
    op.drop_index("ix_ride_request_recipients_ride_id", table_name="ride_request_recipients")
    op.drop_index("ix_ride_request_recipients_driver_id", table_name="ride_request_recipients")
    op.drop_table("ride_request_recipients")
    op.drop_index("idx_rides_dropoff_location", table_name="rides")
    op.drop_index("idx_rides_pickup_location", table_name="rides")
    op.drop_index("ix_rides_status", table_name="rides")
    op.drop_index("ix_rides_rider_id", table_name="rides")
    op.drop_index("ix_rides_accepted_driver_id", table_name="rides")
    op.drop_table("rides")
    op.drop_index("idx_driver_profiles_current_location", table_name="driver_profiles")
    op.drop_index("ix_driver_profiles_availability_status", table_name="driver_profiles")
    op.drop_table("driver_profiles")
    op.drop_index("ix_auth_sessions_user_id", table_name="auth_sessions")
    op.drop_table("auth_sessions")
    op.drop_index("ix_user_devices_user_id", table_name="user_devices")
    op.drop_table("user_devices")
    op.drop_table("user_roles")
    op.drop_table("users")
