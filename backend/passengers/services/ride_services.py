from django.utils import timezone
from django.db import transaction
import logging

from rides.models import RideRequest
from services.matching import build_offers_for_ride, dispatch_next_offer
from realtime.notifications import notify_passenger_event, notify_driver_event

from rides.serializers import RideRequestSerializer

logger = logging.getLogger(__name__)


def check_active_ride(user):
    """Return an existing active ride or None."""
    return RideRequest.objects.filter(
        passenger=user,
        status__in=["pending", "accepted", "in_progress"]
    ).first()


@transaction.atomic
def create_ride_request(user, data, request=None):
    """
    Creates a ride request for the passenger.
    Handles:
    - validation
    - saving the ride
    - generating + dispatching offers
    - sending fallback notifications
    """
    from rides.serializers import RideRequestCreateSerializer

    create_ser = RideRequestCreateSerializer(data=data)
    create_ser.is_valid(raise_exception=True)

    # save ride
    ride = create_ser.save(passenger=user)

    # build offers
    try:
        offers = build_offers_for_ride(ride)

        if offers:
            dispatch_next_offer(ride)
        else:
            notify_passenger_event(
                "no_drivers_available",
                ride,
                "No drivers found nearby."
            )
        candidates = len(offers)

    except Exception:
        logger.exception("Offer dispatch failed for ride_id=%s", ride.id)
        candidates = 0

    # serialize
    serializer = RideRequestSerializer(ride, context={"request": request})

    return {
        "ride_data": serializer.data,
        "driver_candidates": candidates,
        "sequential_notifications": bool(candidates)
    }


def get_current_ride(user, request=None):
    """
    Fetch the current ride for polling endpoint.
    """
    ride = (
        RideRequest.objects.filter(
            passenger=user,
            status__in=["pending", "accepted", "no_drivers"]
        )
        .select_related("driver__driver_profile")
        .first()
    )

    if not ride:
        return None

    serializer = RideRequestSerializer(ride, context={"request": request})

    # build response structure
    return {
        "ride_obj": ride,
        "serialized": serializer.data,
    }


@transaction.atomic
def cancel_ride(user, ride_id, data):
    """
    Cancels the passenger's ride.
    Handles:
    - validation
    - driver restoration
    - notifications
    """
    from rides.serializers import RideCancelSerializer

    try:
        ride = RideRequest.objects.get(id=ride_id, passenger=user)
    except RideRequest.DoesNotExist:
        return {"error": "not_found"}

    if ride.status in ["completed", "cancelled_user", "cancelled_driver"]:
        return {"error": "cannot_cancel", "status": ride.status}

    ser = RideCancelSerializer(data=data)
    ser.is_valid(raise_exception=True)

    had_driver = ride.driver is not None

    ride.status = "cancelled_user"
    ride.cancelled_at = timezone.now()
    ride.cancellation_reason = ser.validated_data.get("reason", "No reason provided")
    ride.save()

    # restore driver availability
    if had_driver:
        try:
            profile = ride.driver.driver_profile
            profile.status = "available"
            profile.save()
            notify_driver_event("ride_cancelled", ride, ride.driver_id, "Passenger cancelled.")
        except Exception:
            logger.exception("Driver update or notification failed")

    # notify passenger
    try:
        notify_passenger_event("ride_cancelled", ride, "Ride cancelled.")
    except Exception:
        logger.exception("Passenger notification failed")

    return {
        "success": True,
        "ride_id": ride.id,
        "was_assigned": had_driver
    }
