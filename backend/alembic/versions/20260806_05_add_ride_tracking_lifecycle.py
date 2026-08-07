"""Add active ride states, audit sequencing, and shared location snapshots."""

from typing import Sequence, Union

from alembic import op
import geoalchemy2
import sqlalchemy as sa


revision: str = "20260806_05"
down_revision: Union[str, Sequence[str], None] = "20260806_04"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


RIDE_STATUSES = (
    "'searching', 'accepted', 'arrived', 'started', "
    "'cancelled_by_rider', 'cancelled_by_driver', 'completed', 'expired'"
)


def upgrade() -> None:
    op.add_column("rides", sa.Column("arrived_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("rides", sa.Column("started_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("rides", sa.Column("state_version", sa.Integer(), server_default="1", nullable=False))

    # `requested` was never emitted by the FastAPI service; normalize any
    # pre-migration legacy rows before tightening the allowed state set.
    op.execute("UPDATE rides SET status = 'searching' WHERE status = 'requested'")
    op.drop_constraint("ck_rides_status", "rides", type_="check")
    op.create_check_constraint("ck_rides_status", "rides", f"status IN ({RIDE_STATUSES})")

    op.add_column("ride_status_history", sa.Column("from_status", sa.String(length=30), nullable=True))
    op.add_column("ride_status_history", sa.Column("state_version", sa.Integer(), nullable=True))
    op.add_column("ride_status_history", sa.Column("actor_role", sa.String(length=20), nullable=True))
    op.execute("UPDATE ride_status_history SET status = 'searching' WHERE status = 'requested'")
    op.execute(
        """
        WITH ordered_history AS (
            SELECT id, row_number() OVER (PARTITION BY ride_id ORDER BY created_at, id) AS version
            FROM ride_status_history
        )
        UPDATE ride_status_history AS history
        SET state_version = ordered_history.version,
            actor_role = 'system'
        FROM ordered_history
        WHERE history.id = ordered_history.id
        """
    )
    op.alter_column("ride_status_history", "state_version", nullable=False)
    op.alter_column("ride_status_history", "actor_role", nullable=False)
    op.drop_constraint("ck_ride_status_history_status", "ride_status_history", type_="check")
    op.create_check_constraint(
        "ck_ride_status_history_status", "ride_status_history", f"status IN ({RIDE_STATUSES})"
    )
    op.create_check_constraint(
        "ck_ride_status_history_actor_role",
        "ride_status_history",
        "actor_role IN ('rider', 'driver', 'system')",
    )
    op.create_unique_constraint("uq_ride_status_history_version", "ride_status_history", ["ride_id", "state_version"])
    op.execute(
        """
        UPDATE rides AS ride
        SET state_version = history.max_version
        FROM (
            SELECT ride_id, max(state_version) AS max_version
            FROM ride_status_history
            GROUP BY ride_id
        ) AS history
        WHERE ride.id = history.ride_id
        """
    )

    op.create_table(
        "ride_participant_locations",
        sa.Column("ride_id", sa.UUID(), nullable=False),
        sa.Column("participant_role", sa.String(length=20), nullable=False),
        sa.Column(
            "location",
            geoalchemy2.Geography(geometry_type="POINT", srid=4326, spatial_index=False),
            nullable=False,
        ),
        sa.Column("captured_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("sequence", sa.Integer(), nullable=False),
        sa.CheckConstraint("participant_role IN ('rider', 'driver')", name="ck_ride_participant_location_role"),
        sa.ForeignKeyConstraint(["ride_id"], ["rides.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("ride_id", "participant_role"),
    )
    op.create_index(
        "idx_ride_participant_locations_location",
        "ride_participant_locations",
        ["location"],
        unique=False,
        postgresql_using="gist",
    )


def downgrade() -> None:
    op.drop_index("idx_ride_participant_locations_location", table_name="ride_participant_locations")
    op.drop_table("ride_participant_locations")
    op.drop_constraint("uq_ride_status_history_version", "ride_status_history", type_="unique")
    op.drop_constraint("ck_ride_status_history_actor_role", "ride_status_history", type_="check")
    op.drop_constraint("ck_ride_status_history_status", "ride_status_history", type_="check")
    op.create_check_constraint(
        "ck_ride_status_history_status",
        "ride_status_history",
        "status IN ('searching', 'requested', 'accepted', 'cancelled_by_rider', "
        "'cancelled_by_driver', 'completed', 'expired')",
    )
    op.drop_column("ride_status_history", "actor_role")
    op.drop_column("ride_status_history", "state_version")
    op.drop_column("ride_status_history", "from_status")
    op.drop_constraint("ck_rides_status", "rides", type_="check")
    op.create_check_constraint(
        "ck_rides_status",
        "rides",
        "status IN ('searching', 'requested', 'accepted', 'cancelled_by_rider', "
        "'cancelled_by_driver', 'completed', 'expired')",
    )
    op.drop_column("rides", "state_version")
    op.drop_column("rides", "started_at")
    op.drop_column("rides", "arrived_at")
