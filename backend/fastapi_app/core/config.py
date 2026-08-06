"""Configuration loaded from environment variables."""

from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime configuration for the FastAPI service."""

    app_name: str = "E-Rick Connect API"
    environment: str = "development"
    debug: bool = True
    api_v1_prefix: str = "/api/v1"
    database_url: str | None = None
    supabase_db_url: str | None = None
    database_sslmode: str | None = None
    jwt_secret_key: str | None = None
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 15
    refresh_token_expire_days: int = 30
    redis_url: str | None = None
    driver_location_min_interval_seconds: int = 3
    ride_request_broadcast_radius_meters: int = Field(default=1_000, ge=100, le=10_000)
    ride_request_search_timeout_seconds: int = Field(default=60, ge=10, le=600)
    ride_request_expiry_check_interval_seconds: int = Field(default=5, ge=1, le=60)
    cors_origins: list[str] = [
        "http://localhost:3000",
        "http://localhost:8080",
        "http://10.0.2.2:8000",
    ]

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    @field_validator("database_url", "supabase_db_url", mode="before")
    @classmethod
    def validate_database_url(cls, value: str | None) -> str | None:
        """Restrict configured connection URLs to PostgreSQL."""

        if value and not value.startswith(
            ("postgres://", "postgresql://", "postgresql+psycopg://", "postgresql+asyncpg://")
        ):
            raise ValueError("Database URLs must use a PostgreSQL scheme")
        return value

    @property
    def resolved_database_url(self) -> str | None:
        """Prefer the Supabase override, matching Oppora's configuration."""

        database_url = self.supabase_db_url or self.database_url
        if database_url is None:
            return None
        return database_url.replace("postgresql+psycopg://", "postgresql+asyncpg://", 1).replace(
            "postgresql://", "postgresql+asyncpg://", 1
        ).replace("postgres://", "postgresql+asyncpg://", 1)

    @property
    def database_connect_args(self) -> dict[str, object]:
        """Set asyncpg options required by Supabase pooler connections."""

        database_url = self.resolved_database_url or ""
        if "pooler.supabase.com" not in database_url:
            return {}
        connect_args: dict[str, object] = {"statement_cache_size": 0}
        if self.database_sslmode != "disable":
            connect_args["ssl"] = "require"
        return connect_args

    def require_jwt_secret(self) -> str:
        """Return the application token secret, failing safely when it is absent."""

        if not self.jwt_secret_key or len(self.jwt_secret_key) < 32:
            raise RuntimeError(
                "JWT_SECRET_KEY must be set to a random value of at least 32 characters."
            )
        return self.jwt_secret_key

    def require_redis_url(self) -> str:
        """Return the Redis endpoint required by live driver availability."""

        if not self.redis_url or not self.redis_url.startswith(("redis://", "rediss://")):
            raise RuntimeError("REDIS_URL must be a redis:// or rediss:// URL.")
        return self.redis_url


@lru_cache
def get_settings() -> Settings:
    """Return the process-wide parsed settings instance."""

    return Settings()
