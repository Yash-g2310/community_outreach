"""Add the searching ride state used while matching drivers."""

from typing import Sequence, Union

from alembic import op


revision: str = "20260806_03"
down_revision: Union[str, Sequence[str], None] = "20260805_02"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.drop_constraint("ck_rides_status", "rides", type_="check")
    op.create_check_constraint(
        "ck_rides_status",
        "rides",
        "status IN ('searching', 'requested', 'accepted', 'cancelled_by_rider', "
        "'cancelled_by_driver', 'completed', 'expired')",
    )
    op.drop_constraint("ck_ride_status_history_status", "ride_status_history", type_="check")
    op.create_check_constraint(
        "ck_ride_status_history_status",
        "ride_status_history",
        "status IN ('searching', 'requested', 'accepted', 'cancelled_by_rider', "
        "'cancelled_by_driver', 'completed', 'expired')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_ride_status_history_status", "ride_status_history", type_="check")
    op.create_check_constraint(
        "ck_ride_status_history_status",
        "ride_status_history",
        "status IN ('requested', 'accepted', 'cancelled_by_rider', "
        "'cancelled_by_driver', 'completed', 'expired')",
    )
    op.drop_constraint("ck_rides_status", "rides", type_="check")
    op.create_check_constraint(
        "ck_rides_status",
        "rides",
        "status IN ('requested', 'accepted', 'cancelled_by_rider', "
        "'cancelled_by_driver', 'completed', 'expired')",
    )
