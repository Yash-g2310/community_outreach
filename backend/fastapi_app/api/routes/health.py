"""Service health endpoints."""

from fastapi import APIRouter, status


router = APIRouter(prefix="/health", tags=["health"])


@router.get("", status_code=status.HTTP_200_OK)
async def health_check() -> dict[str, str]:
    """Confirm that the FastAPI application is accepting requests."""

    return {"status": "ok"}
