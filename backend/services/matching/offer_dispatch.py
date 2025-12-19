"""
Offer dispatch and expiry handling.

Handles the daisy-chain pattern for ride offers:
1. Offer sent to driver
2. Wait for response or timeout
3. If expired/rejected, offer to next driver
4. Repeat until accepted or no drivers left
"""

import logging
from typing import Optional

from django.utils import timezone
from channels.layers import get_channel_layer
from asgiref.sync import async_to_sync

from rides.models import RideRequest, RideOffer
from rides.serializers import RideRequestSerializer
from rides.tasks import expire_ride_offer_task

logger = logging.getLogger(__name__)


def dispatch_next_offer(ride: RideRequest) -> bool:
    """
    Send the next pending ride offer to the specific driver.
    Uses the daisy-chain pattern: driver_<driver_id> group.
    
    Args:
        ride: RideRequest instance
    
    Returns:
        True if an offer was dispatched, False if no pending offers
    """
    # Get next unsent pending offer (ordered queue)
    offer = (
        ride.offers
        .filter(status="pending", sent_at__isnull=True)
        .order_by("order")
        .select_related("driver")
        .first()
    )
    if not offer:
        return False

    channel_layer = get_channel_layer()
    if channel_layer is None:
        logger.warning("No channel layer available for dispatch")
        return False

    # Mark offer as "sent"
    offer.sent_at = timezone.now()
    offer.save(update_fields=["sent_at"])

    # Serialize ride data
    payload = RideRequestSerializer(ride).data

    # Send to the driver's personal group
    send_payload = {
        "type": "ride_offer",
        "ride_data": payload,
        "offer_id": offer.id,
    }
    
    logger.debug("Dispatching offer to driver_%s for ride %s", offer.driver_id, ride.id)
    async_to_sync(channel_layer.group_send)(f"driver_{offer.driver_id}", send_payload)

    # Schedule Celery expiry task for this offer
    expire_ride_offer_task.apply_async((offer.id,), countdown=20)
    
    return True


def expire_offer_and_dispatch(offer: RideOffer) -> bool:
    """
    Mark an offer as expired, notify the driver, then dispatch the next offer.
    If no offers remain, notify the passenger that no drivers are available.
    
    Args:
        offer: RideOffer instance to expire
    
    Returns:
        True if next offer was dispatched, False otherwise
    """
    # Only pending offers can expire
    if offer.status != "pending":
        return False

    offer.status = "expired"
    offer.responded_at = timezone.now()
    offer.save(update_fields=["status", "responded_at"])

    channel_layer = get_channel_layer()
    if channel_layer is None:
        return False

    # Notify DRIVER that their offer expired
    expired_payload = {
        "type": "ride_expired",
        "ride_id": offer.ride_id,
        "message": "Your ride offer has timed out.",
    }
    logger.debug("Notifying driver_%s of expired offer", offer.driver_id)
    async_to_sync(channel_layer.group_send)(f"driver_{offer.driver_id}", expired_payload)

    # Attempt to send the next pending offer
    dispatched = dispatch_next_offer(offer.ride)

    # If no pending offers left AND dispatch failed → notify passenger
    has_pending = offer.ride.offers.filter(status="pending").exists()

    if not dispatched and not has_pending:
        # Update ride status
        offer.ride.status = "no_drivers"
        offer.ride.save(update_fields=["status"])

        # Notify PASSENGER
        passenger_expired_payload = {
            "type": "ride_expired",
            "ride_id": offer.ride_id,
            "message": "No drivers accepted your ride request. Please try again later.",
        }
        logger.debug("Notifying passenger user_%s - no drivers available", offer.ride.passenger_id)
        async_to_sync(channel_layer.group_send)(
            f"user_{offer.ride.passenger_id}", 
            passenger_expired_payload
        )

    return dispatched
