"""Alembic environment for the FastAPI/Supabase database."""

import asyncio
from logging.config import fileConfig

from alembic import context
from sqlalchemy import pool
from sqlalchemy.ext.asyncio import create_async_engine

from fastapi_app.core.config import get_settings
from fastapi_app.db.base import Base
import fastapi_app.db.models  # noqa: F401 - registers all ORM tables on Base.metadata


config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def get_database_url() -> str:
    database_url = get_settings().resolved_database_url
    if database_url is None:
        raise RuntimeError("SUPABASE_DB_URL or DATABASE_URL must be configured in backend/.env")
    return database_url


def run_migrations_offline() -> None:
    context.configure(
        url=get_database_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: object) -> None:
    context.configure(connection=connection, target_metadata=target_metadata, compare_type=True)
    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online() -> None:
    settings = get_settings()
    connectable = create_async_engine(
        get_database_url(),
        poolclass=pool.NullPool,
        connect_args=settings.database_connect_args,
    )
    try:
        async with connectable.connect() as connection:
            await connection.run_sync(do_run_migrations)
    finally:
        await connectable.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())
