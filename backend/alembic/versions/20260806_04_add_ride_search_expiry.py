"""Track when a searching ride should expire."""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "20260806_04"
down_revision: Union[str, Sequence[str], None] = "20260806_03"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("rides", sa.Column("search_expires_at", sa.DateTime(timezone=True), nullable=True))
    op.create_index("ix_rides_search_expires_at", "rides", ["search_expires_at"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_rides_search_expires_at", table_name="rides")
    op.drop_column("rides", "search_expires_at")
