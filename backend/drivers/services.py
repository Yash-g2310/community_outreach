from django.utils import timezone

from drivers.models import DriverProfile
from rides.models import RideRequest
from common.utils.geo import calculate_distance
from realtime.broadcast import broadcast_driver_location, broadcast_driver_status


class RideNotFoundError(Exception):
    pass

class OfferExpiredError(Exception):
    pass

class RideNotAvailableError(Exception):
    pass


# DRIVER STATUS UPDATE
def update_driver_status(profile: DriverProfile, new_status: str):
    """
    Update driver availability status.
    This broadcasts status change to nearby passengers via WebSocket.
    """
    profile.status = new_status
    profile.save(update_fields=["status"])

    # WebSocket: notify nearby passengers of driver status change
    if profile.current_latitude and profile.current_longitude:
        broadcast_driver_status(
            driver_id=profile.user_id,
            status=new_status,
            lat=float(profile.current_latitude),
            lon=float(profile.current_longitude),
            username=profile.user.username if profile.user else None,
            vehicle_number=profile.vehicle_number,
        )

    return profile


def update_driver_location(profile: DriverProfile, lat, lon):
    """
    Update driver location — used by:
    - HTTP fallback
    - WebSocket driver tracking events
    """
    profile.current_latitude = lat
    profile.current_longitude = lon
    profile.last_location_update = timezone.now()
    profile.save(update_fields=["current_latitude", "current_longitude", "last_location_update"])

    # Push location to nearby passengers via WebSocket
    broadcast_driver_location(
        driver_id=profile.user_id,
        lat=float(lat),
        lon=float(lon),
        username=profile.user.username if profile.user else None,
        vehicle_number=profile.vehicle_number,
        status=profile.status,
        force=True,  # Force since this is explicit HTTP call
    )

    return profile


# POLLING-BASED NEARBY RIDES (Fallback / Legacy)
def find_nearby_pending_rides(lat, lon):
    """
    Find nearby pending ride requests (legacy fallback when WS is not active).
    """
    pending = RideRequest.objects.filter(status="pending")

    # Annotate with distance
    rides_with_distance = []
    for ride in pending:
        dist = calculate_distance(float(lat), float(lon),
                                  float(ride.pickup_latitude),
                                  float(ride.pickup_longitude))
        rides_with_distance.append((dist, ride))

    # sort ascending
    rides_with_distance.sort(key=lambda x: x[0])

    return [r for (_, r) in rides_with_distance]