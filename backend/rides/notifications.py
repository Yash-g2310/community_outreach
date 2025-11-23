"""Contains the helper functions that send notifications to drivers and passengers."""

from __future__ import annotations

from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from django.utils import timezone
import logging

from .models import DriverProfile, RideOffer, RideRequest
from .serializers import RideRequestSerializer
from .utils import calculate_distance

logger = logging.getLogger(__name__)


def build_offers_for_ride(ride: RideRequest) -> list[RideOffer]:
    """
    Build the ordered RideOffer list (queue) for one ride.

    Used right before sending WS ride_offer events:
        await channel_layer.group_send(
            f"driver_{driver_id}",
            {"type": "ride_offer", "ride_data": ..., "offer_id": offer.id}
        )
    """

    # 1. Fetch currently available drivers with stored live location
    available_drivers = (
        DriverProfile.objects.select_related("user")
        .filter(
            status="available",
            current_latitude__isnull=False,
            current_longitude__isnull=False,
        )
    )

    # 2. Compute distance from ride pickup for each driver
    candidates: list[tuple[DriverProfile, float]] = []
    for profile in available_drivers:
        distance = calculate_distance(
            float(ride.pickup_latitude),
            float(ride.pickup_longitude),
            float(profile.current_latitude),
            float(profile.current_longitude),
        )
        # Only keep drivers inside broadcast radius
        if distance <= float(ride.broadcast_radius):
            candidates.append((profile, distance))

    # 3. Sort closest → farthest
    candidates.sort(key=lambda item: item[1])

    # 4. Clear old offers to avoid stale/outdated queue
    ride.offers.all().delete()

    # 5. Insert updated queue (ordered RideOffer rows)
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
    """
    Send the next pending ride offer to the specific driver using:
        driver_<driver_id>
    This matches the unified AppConsumer (ride_offer handler).
    """

    # 1. Get next unsent pending offer (ordered queue)
    offer = (
        ride.offers
        .filter(status="pending", sent_at__isnull=True)
        .order_by("order")
        .select_related("driver")
        .first()
    )
    if not offer:
        return False   # No pending offers left

    # 2. Download channel layer
    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    # 3. Mark offer as "sent"
    offer.sent_at = timezone.now()
    offer.save(update_fields=["sent_at"])

    # 4. Serialize ride data
    payload = RideRequestSerializer(ride).data

    # 5. Send to the driver's personal group
    send_payload = {
        "type": "ride_offer",      # triggers ride_offer() handler in AppConsumer
        "ride_data": payload,
        "offer_id": offer.id,
    }
    logger.debug("WS -> driver_%s: %s", offer.driver_id, send_payload)
    async_to_sync(channel_layer.group_send)(f"driver_{offer.driver_id}", send_payload)

    return True


def expire_offer_and_dispatch(offer: RideOffer) -> bool:
    """
    Mark this offer as expired, notify the driver, then dispatch the next offer.
    If no offers remain, notify the passenger that no drivers are available.
    """

    # 1. Only pending offers can expire
    if offer.status != "pending":
        return False

    offer.status = "expired"
    offer.responded_at = timezone.now()
    offer.save(update_fields=["status", "responded_at"])

    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    # 2. Notify DRIVER that their offer expired
    expired_payload = {
        "type": "ride_expired",         # -> AppConsumer.ride_expired()
        "ride_id": offer.ride_id,
        "message": "Your ride offer has timed out.",
    }
    logger.debug("WS -> driver_%s: %s", offer.driver_id, expired_payload)
    async_to_sync(channel_layer.group_send)(f"driver_{offer.driver_id}", expired_payload)

    # 3. Attempt to send the next pending offer
    dispatched = dispatch_next_offer(offer.ride)

    # 4. If no pending offers left AND dispatch failed → notify passenger
    has_pending = offer.ride.offers.filter(status="pending").exists()

    if not dispatched and not has_pending:
        # Update ride status
        offer.ride.status = "no_drivers"
        offer.ride.save(update_fields=["status"])

        # Notify PASSENGER that no drivers have accepted their ride request
        # This path occurs after offers were created and dispatched but none accepted.
        # Send 'ride_expired' to passenger to indicate the sequential-offers flow failed.
        passenger_expired_payload = {
            "type": "ride_expired",   # -> AppConsumer.ride_expired() for passenger
            "ride_id": offer.ride_id,
            "message": "No drivers accepted your ride request. Please try again later.",
        }
        logger.debug("WS -> user_%s: %s", offer.ride.passenger_id, passenger_expired_payload)
        async_to_sync(channel_layer.group_send)(f"user_{offer.ride.passenger_id}", passenger_expired_payload)

    return dispatched


def notify_driver_event(event_type: str, ride: RideRequest, driver_id: int | None, message: str = "") -> bool:
    """
    Send an event to a specific driver using their personal group:
        driver_<driver_id>

    event_type should match one of AppConsumer's server-event handlers, like:
        - ride_offer
        - ride_expired
        - ride_cancelled
        - ride_accepted
    """

    if not driver_id:
        return False

    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    payload = {
        "type": event_type,            # maps to AppConsumer.<event_type>()
        "ride_id": ride.id,
        "driver_id": driver_id,
        "ride_data": RideRequestSerializer(ride).data
    }

    if message:
        payload["message"] = message

    # Send directly to this driver
    logger.debug("WS -> driver_%s: %s", driver_id, payload)
    async_to_sync(channel_layer.group_send)(f"driver_{driver_id}", payload)

    return True


def notify_passenger_event(event_type: str, ride: RideRequest, message: str = "") -> bool:
    """
    Send ride-related event to the passenger through:
        user_<passenger_id>

    event_type must match AppConsumer's server-event handler, like:
        - no_drivers_available
        - ride_accepted
        - ride_cancelled
        - ride_expired
    """

    passenger_id = ride.passenger_id
    if not passenger_id:
        return False

    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    payload = {
        "type": event_type,              # calls AppConsumer.<event_type>()
        "ride_id": ride.id,
        "status": ride.status,
        "ride_data": RideRequestSerializer(ride).data
    }

    if message:
        payload["message"] = message

    logger.debug("WS -> user_%s: %s", passenger_id, payload)
    async_to_sync(channel_layer.group_send)(f"user_{passenger_id}", payload)

    return True
