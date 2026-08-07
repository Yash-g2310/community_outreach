"""Top-level versioned API router."""

from fastapi import APIRouter

from fastapi_app.api.routes import auth, driver, health, ride, rider


api_router = APIRouter()
api_router.include_router(health.router)
api_router.include_router(auth.router)
api_router.include_router(driver.router)
api_router.include_router(rider.router)
api_router.include_router(ride.router)
