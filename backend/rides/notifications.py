from __future__ import annotations

from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from django.utils import timezone

from .models import DriverProfile, RideOffer, RideRequest
from .serializers import RideRequestSerializer
from .utils import calculate_distance


def build_offers_for_ride(ride: RideRequest) -> list[RideOffer]:
    """Populate the RideOffer queue for the provided ride based on distance."""
    available_drivers = (
        DriverProfile.objects.select_related("user")
        .filter(
            status="available",
            current_latitude__isnull=False,
            current_longitude__isnull=False,
        )
    )

    candidates: list[tuple[DriverProfile, float]] = []
    for profile in available_drivers:
        distance = calculate_distance(
            ride.pickup_latitude,
            ride.pickup_longitude,
            profile.current_latitude,
            profile.current_longitude,
        )
        if distance <= ride.broadcast_radius:
            candidates.append((profile, distance))

    candidates.sort(key=lambda item: item[1])

    # Reset previous offers before inserting the latest ordering
    ride.offers.all().delete()

    offers: list[RideOffer] = []
    for order, (profile, _) in enumerate(candidates):
        offer = RideOffer.objects.create(
            ride=ride,
            driver=profile.user,
            order=order,
            status="pending",
        )
        offers.append(offer)

    return offers


def dispatch_next_offer(ride: RideRequest) -> bool:
    """Send the next pending ride offer to its targeted driver via WebSocket."""
    offer = (
        ride.offers.filter(status="pending", sent_at__isnull=True)
        .order_by("order")
        .select_related("driver")
        .first()
    )
    if not offer:
        return False

    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    offer.sent_at = timezone.now()
    offer.save(update_fields=["sent_at"])

    payload = RideRequestSerializer(ride).data
    async_to_sync(channel_layer.group_send)(
        "available_drivers",
        {
            "type": "new_ride_request",
            "ride_data": payload,
            "driver_id": offer.driver_id,
        },
    )

    return True


def expire_offer_and_dispatch(offer: RideOffer) -> bool:
    """Mark an offer as expired and attempt to notify the next driver."""
    if offer.status != "pending":
        return False

    offer.status = "expired"
    offer.responded_at = timezone.now()
    offer.save(update_fields=["status", "responded_at"])

    # Notify the driver whose offer just expired
    notify_driver_event(
        "ride_expired",
        offer.ride,
        offer.driver_id,
        "Your ride offer has timed out.",
    )

    dispatched = dispatch_next_offer(offer.ride)
    if not dispatched and not offer.ride.offers.filter(status="pending").exists():
        offer.ride.status = "no_drivers"
        offer.ride.save(update_fields=["status"])
        # Notify passenger that no drivers are available
        notify_passenger_event(
            "no_drivers_available",
            offer.ride,
            "No drivers accepted your ride request. Please try again later.",
        )

    return dispatched


def notify_driver_event(event_type: str, ride: RideRequest, driver_id: int | None, message: str = "") -> bool:
    if not driver_id:
        return False

    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    payload = {
        "type": event_type,
        "ride_id": ride.id,
        "driver_id": driver_id,
    }
    if message:
        payload["message"] = message
    payload["ride_data"] = RideRequestSerializer(ride).data

    async_to_sync(channel_layer.group_send)("available_drivers", payload)
    return True


def notify_passenger_event(event_type: str, ride: RideRequest, message: str = "") -> bool:
    """Send a WebSocket event to a specific passenger about their ride status."""
    if not ride.passenger_id:
        return False

    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    payload = {
        "type": event_type,
        "ride_id": ride.id,
        "status": ride.status,
    }
    if message:
        payload["message"] = message
    payload["ride_data"] = RideRequestSerializer(ride).data

    # Send to passenger-specific group
    async_to_sync(channel_layer.group_send)(
        f"passenger_{ride.passenger_id}",
        payload
    )
    return True


def broadcast_driver_status_change(driver_profile: DriverProfile, old_status: str = None) -> bool:
    """
    Broadcast driver status change to all passengers listening for nearby drivers updates.
    
    Args:
        driver_profile: The DriverProfile that changed status
        old_status: The previous status (optional, for logging/debugging)
    
    Returns:
        True if broadcast succeeded, False otherwise
    """
    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    payload = {
        "type": "driver_status_changed",
        "driver_id": driver_profile.id,
        "status": driver_profile.status,
        "latitude": float(driver_profile.current_latitude) if driver_profile.current_latitude else None,
        "longitude": float(driver_profile.current_longitude) if driver_profile.current_longitude else None,
        "message": f"Driver {driver_profile.user.username} is now {driver_profile.status}"
    }

    # Broadcast to all passengers
    async_to_sync(channel_layer.group_send)(
        "all_passengers",
        payload
    )
    return True


def broadcast_driver_location_update(driver_profile: DriverProfile) -> bool:
    """
    Broadcast significant driver location changes to passengers.
    Only broadcasts for available drivers with valid location.
    
    Args:
        driver_profile: The DriverProfile with updated location
    
    Returns:
        True if broadcast succeeded, False otherwise
    """
    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    # Only broadcast for available drivers
    if driver_profile.status != 'available':
        return False
    
    if not driver_profile.current_latitude or not driver_profile.current_longitude:
        return False

    payload = {
        "type": "driver_location_updated",
        "driver_id": driver_profile.id,
        "latitude": float(driver_profile.current_latitude),
        "longitude": float(driver_profile.current_longitude)
    }

    # Broadcast to all passengers
    async_to_sync(channel_layer.group_send)(
        "all_passengers",
        payload
    )
    return True
