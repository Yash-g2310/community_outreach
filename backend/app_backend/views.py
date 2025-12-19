import os
import redis
from django.utils import timezone
from rest_framework.decorators import api_view
from rest_framework.response import Response
from rest_framework import status
from channels.layers import get_channel_layer

from rides.models import RideRequest
from rides.tasks import expire_ride_offer_task


@api_view(["GET"])
def health_check(request):
    """Health check endpoint for monitoring system status"""
    
    health_status = {
        "status": "healthy",
        "timestamp": timezone.now().isoformat(),
        "services": {}
    }

    # Database check
    try:
        RideRequest.objects.count()
        health_status["services"]["database"] = "healthy"
    except Exception as e:
        health_status["services"]["database"] = f"unhealthy: {e}"
        health_status["status"] = "unhealthy"

    # Redis check
    try:
        redis_client = redis.Redis(
            host=os.getenv("REDIS_HOST", "localhost"),
            port=int(os.getenv("REDIS_PORT", 6379)),
            db=0,
            socket_timeout=3
        )
        redis_client.ping()
        health_status["services"]["redis"] = "healthy"
    except Exception as e:
        health_status["services"]["redis"] = f"unhealthy: {e}"
        health_status["status"] = "unhealthy"

    # Channel layer check
    try:
        channel_layer = get_channel_layer()
        if channel_layer is not None:
            health_status["services"]["channels"] = "healthy"
        else:
            health_status["services"]["channels"] = "unhealthy: no channel layer"
            health_status["status"] = "unhealthy"
    except Exception as e:
        health_status["services"]["channels"] = f"unhealthy: {e}"
        health_status["status"] = "unhealthy"

    # Celery check
    try:
        if expire_ride_offer_task:
            health_status["services"]["celery"] = "healthy"
        else:
            health_status["services"]["celery"] = "unhealthy: task not registered"
            health_status["status"] = "unhealthy"
    except Exception as e:
        health_status["services"]["celery"] = f"unhealthy: {e}"
        health_status["status"] = "unhealthy"

    status_code = (
        status.HTTP_200_OK
        if health_status["status"] == "healthy"
        else status.HTTP_503_SERVICE_UNAVAILABLE
    )

    return Response(health_status, status=status_code)
