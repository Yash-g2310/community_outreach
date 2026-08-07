"""Add secure password storage for FastAPI authentication."""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "20260805_02"
down_revision: Union[str, Sequence[str], None] = "20260804_01"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("password_hash", sa.String(length=255), nullable=True))
    # Existing rows from the previous system must reset a password before FastAPI login.
    op.execute("UPDATE users SET password_hash = 'legacy-password-reset-required' WHERE password_hash IS NULL")
    op.alter_column("users", "password_hash", nullable=False)


def downgrade() -> None:
    op.drop_column("users", "password_hash")
