"""
Notification helpers for sending WebSocket messages to connected clients.

This module provides functions to:
- Notify nearby passengers of driver location/status changes (via Redis GEO)
- Send ride-related events to drivers and passengers
- Build and dispatch ride offers (daisy chain)
"""

from __future__ import annotations

import logging
from typing import Dict, Any

from asgiref.sync import async_to_sync
from channels.db import database_sync_to_async
from channels.layers import get_channel_layer
from django.contrib.auth import get_user_model
from django.utils import timezone

from drivers.models import DriverProfile
from .utils import calculate_distance
from .broadcast import broadcast_driver_location, broadcast_driver_status

User = get_user_model()
logger = logging.getLogger(__name__)


# ---------------------- Driver Info Helper ----------------------

@database_sync_to_async
def _get_driver_info(driver_id: int) -> Dict[str, Any]:
    """Fetch driver username and vehicle number for notifications."""
    user = User.objects.filter(id=driver_id).first()
    profile = DriverProfile.objects.filter(user_id=driver_id).first()
    return {
        "username": getattr(user, "username", None),
        "vehicle_number": getattr(profile, "vehicle_number", None),
    }


# ---------------------- Nearby Passenger Notifications ----------------------

async def notify_nearby_passengers_async(
    channel_layer,
    driver_id: int,
    lat: float,
    lon: float,
    event_type: str = "driver_location_updated",
    radius_override: int = None,
    extra: Dict[str, Any] = None,
):
    """
    Notify connected passengers whose subscription radius includes driver's location.
    
    DEPRECATED: This function is kept for backward compatibility.
    New code should use broadcast_driver_location_async() from realtime.broadcast.
    
    Args:
        channel_layer: get_channel_layer() or self.channel_layer (unused, kept for compatibility)
        driver_id: ID of the driver
        lat: Driver's current latitude
        lon: Driver's current longitude
        event_type: one of "driver_location_updated" or "driver_status_changed"
        radius_override: Override passenger's radius (optional, unused in new impl)
        extra: Additional keys to include (e.g., status, message)
    """
    from .broadcast import broadcast_driver_location_async, broadcast_driver_status_async
    
    extra = extra or {}
    
    # Fetch driver info
    try:
        driver_info = await _get_driver_info(driver_id)
    except Exception:
        driver_info = {"username": None, "vehicle_number": None}

    # Route to appropriate broadcast function based on event type
    if event_type == "driver_status_changed":
        await broadcast_driver_status_async(
            driver_id=driver_id,
            status=extra.get("status", "available"),
            lat=lat,
            lon=lon,
            username=driver_info.get("username"),
            vehicle_number=driver_info.get("vehicle_number"),
        )
    else:
        await broadcast_driver_location_async(
            driver_id=driver_id,
            lat=lat,
            lon=lon,
            username=driver_info.get("username"),
            vehicle_number=driver_info.get("vehicle_number"),
            status="available",
            force=True,  # Force broadcast since this is explicitly called
        )


def notify_nearby_passengers_sync(
    channel_layer,
    driver_id: int,
    lat: float,
    lon: float,
    event_type: str = "driver_location_updated",
    radius_override: int = None,
    extra: Dict[str, Any] = None,
):
    """
    Synchronous wrapper for notify_nearby_passengers_async.
    
    DEPRECATED: Use broadcast_driver_location() from realtime.broadcast instead.
    """
    extra = extra or {}
    
    # Fetch driver info synchronously
    try:
        user = User.objects.filter(id=driver_id).first()
        profile = DriverProfile.objects.filter(user_id=driver_id).first()
        username = getattr(user, "username", None)
        vehicle_number = getattr(profile, "vehicle_number", None)
    except Exception:
        username = None
        vehicle_number = None

    # Route to appropriate broadcast function
    if event_type == "driver_status_changed":
        broadcast_driver_status(
            driver_id=driver_id,
            status=extra.get("status", "available"),
            lat=lat,
            lon=lon,
            username=username,
            vehicle_number=vehicle_number,
        )
    else:
        broadcast_driver_location(
            driver_id=driver_id,
            lat=lat,
            lon=lon,
            username=username,
            vehicle_number=vehicle_number,
            status="available",
            force=True,
        )


# ---------------------- Ride Event Notifications ----------------------

def notify_driver_event(
    event_type: str,
    ride,
    driver_id: int | None,
    message: str = "",
    extra: Dict[str, Any] = None,
) -> bool:
    """
    Send an event to a specific driver using their personal group: driver_<driver_id>
    
    Args:
        event_type: Handler name in consumer (ride_offer, ride_expired, ride_cancelled, ride_accepted)
        ride: RideRequest model instance
        driver_id: Target driver's user ID
        message: Optional message to include
        extra: Additional payload data
    
    Returns:
        True if sent successfully, False otherwise
    """
    if not driver_id:
        return False

    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    from rides.serializers import RideRequestSerializer
    
    payload = {
        "type": event_type,
        "ride_id": ride.id,
        "driver_id": driver_id,
        "ride_data": RideRequestSerializer(ride).data,
        **(extra or {}),
    }

    if message:
        payload["message"] = message

    logger.debug("WS -> driver_%s: %s", driver_id, payload)
    async_to_sync(channel_layer.group_send)(f"driver_{driver_id}", payload)

    return True


def notify_passenger_event(
    event_type: str,
    ride,
    message: str = "",
    extra: Dict[str, Any] = None,
) -> bool:
    """
    Send ride-related event to the passenger through: user_<passenger_id>
    
    Args:
        event_type: Handler name in consumer (no_drivers_available, ride_accepted, ride_cancelled, ride_expired)
        ride: RideRequest model instance
        message: Optional message to include
        extra: Additional payload data
    
    Returns:
        True if sent successfully, False otherwise
    """
    passenger_id = ride.passenger_id
    if not passenger_id:
        return False

    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    from rides.serializers import RideRequestSerializer

    payload = {
        "type": event_type,
        "ride_id": ride.id,
        "status": ride.status,
        "ride_data": RideRequestSerializer(ride).data,
        **(extra or {}),
    }

    if message:
        payload["message"] = message

    logger.debug("WS -> user_%s: %s", passenger_id, payload)
    async_to_sync(channel_layer.group_send)(f"user_{passenger_id}", payload)

    return True


# ---------------------- Ride Offer Management ----------------------
# These functions delegate to services.matching for the actual logic.
# Kept here for backward compatibility with existing code.

def build_offers_for_ride(ride) -> list:
    """
    Build the ordered RideOffer list (queue) for one ride.
    
    DEPRECATED: Use services.matching.build_offers_for_ride instead.
    """
    from services.matching import build_offers_for_ride as _build
    return _build(ride)


def dispatch_next_offer(ride) -> bool:
    """
    Send the next pending ride offer to the specific driver.
    
    DEPRECATED: Use services.matching.dispatch_next_offer instead.
    """
    from services.matching import dispatch_next_offer as _dispatch
    return _dispatch(ride)


def expire_offer_and_dispatch(offer) -> bool:
    """
    Mark an offer as expired, notify the driver, then dispatch the next offer.
    
    DEPRECATED: Use services.matching.expire_offer_and_dispatch instead.
    """
    from services.matching import expire_offer_and_dispatch as _expire
    return _expire(offer)
