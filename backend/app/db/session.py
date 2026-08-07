"""Async SQLAlchemy engine and request-scoped session dependency."""

from collections.abc import AsyncGenerator
from functools import lru_cache

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import get_settings


@lru_cache
def get_session_factory() -> async_sessionmaker[AsyncSession]:
    """Create the reusable session factory after DATABASE_URL is configured."""

    settings = get_settings()
    database_url = settings.resolved_database_url
    if database_url is None:
        raise RuntimeError("DATABASE_URL or SUPABASE_DB_URL is required before database endpoints can be used")

    engine = create_async_engine(
        database_url,
        pool_pre_ping=True,
        connect_args=settings.database_connect_args,
    )
    return async_sessionmaker(engine, expire_on_commit=False)


async def get_db_session() -> AsyncGenerator[AsyncSession, None]:
    """Provide one transactional session for each API request."""

    async with get_session_factory()() as session:
        yield session
