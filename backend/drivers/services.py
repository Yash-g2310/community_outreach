from django.utils import timezone

from drivers.models import DriverProfile
from rides.models import RideRequest
from rides import notifications


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
    This may broadcast events to WebSockets or trigger downstream logic.
    """
    profile.status = new_status
    profile.save(update_fields=["status"])

    # WebSocket: notify passenger groups OR global driver tracking groups
    notifications.broadcast_driver_status(profile)

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

    # Push to WebSocket passenger tracking channels
    notifications.broadcast_driver_location(profile)

    return profile


# POLLING-BASED NEARBY RIDES (Fallback / Legacy)
def find_nearby_pending_rides(lat, lon):
    """
    Find nearby pending ride requests (legacy fallback when WS is not active).
    Your existing logic uses calculate_distance(), so we simply reuse that.
    """
    pending = RideRequest.objects.filter(status="pending")

    # Compute distance manually (your existing function)
    from rides.views import calculate_distance  # import lazily to avoid cross-import at startup

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