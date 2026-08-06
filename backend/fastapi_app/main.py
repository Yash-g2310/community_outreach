"""FastAPI application entry point."""

import asyncio
import logging
from contextlib import asynccontextmanager
from contextlib import suppress
from typing import AsyncIterator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from fastapi_app.api.router import api_router
from fastapi_app.api.routes.websocket import router as websocket_router
from fastapi_app.api.routes.websocket import connections
from fastapi_app.core.config import get_settings
from fastapi_app.services.ride_expiration import expire_due_ride_requests

logger = logging.getLogger(__name__)


async def _notify_expired_rides() -> None:
    for ride in await expire_due_ride_requests():
        await connections.send_to_user(
            ride.rider_id,
            {"type": "ride_request_expired", "ride_id": str(ride.ride_id)},
        )
        for driver_id in ride.driver_ids:
            await connections.send_to_user(
                driver_id,
                {
                    "type": "ride_request_closed",
                    "ride_id": str(ride.ride_id),
                    "reason": "no_driver_accepted",
                },
            )


async def _ride_expiry_loop() -> None:
    while True:
        try:
            await _notify_expired_rides()
        except Exception:
            logger.exception("Unable to expire overdue ride requests")
        await asyncio.sleep(get_settings().ride_request_expiry_check_interval_seconds)


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    expiry_task = asyncio.create_task(_ride_expiry_loop())
    try:
        yield
    finally:
        expiry_task.cancel()
        with suppress(asyncio.CancelledError):
            await expiry_task


def create_app() -> FastAPI:
    """Create the ASGI application and register shared infrastructure."""

    settings = get_settings()
    app = FastAPI(
        title=settings.app_name,
        debug=settings.debug,
        version="0.1.0",
        openapi_url=f"{settings.api_v1_prefix}/openapi.json",
        docs_url="/docs",
        redoc_url="/redoc",
        lifespan=lifespan,
    )
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    app.include_router(api_router, prefix=settings.api_v1_prefix)
    app.include_router(websocket_router)
    return app


app = create_app()
