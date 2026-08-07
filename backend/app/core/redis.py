"""Redis access for ephemeral real-time driver availability."""

from functools import lru_cache

from redis.asyncio import Redis

from app.core.config import get_settings


DRIVER_GEO_INDEX_KEY = "drivers:available:geo"


def driver_state_key(driver_id: str) -> str:
    return f"driver:state:{driver_id}"


@lru_cache
def get_redis() -> Redis:
    """Create the shared async Redis client after REDIS_URL is configured."""

    return Redis.from_url(get_settings().require_redis_url(), decode_responses=True)
