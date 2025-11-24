# passengers/services.py

from drivers.models import DriverProfile
from rides.models import RideRequest
from rides.serializers import RideRequestSerializer
from rides.utils import calculate_distance


def get_passenger_profile(user):
    """Return serialized passenger profile data."""
    from ..serializers import UserSerializer
    return UserSerializer(user, context={"request": None}).data


def update_passenger_profile(user, data, request=None):
    """Update passenger profile with partial data."""
    from ..serializers import UserSerializer
    ser = UserSerializer(user, data=data, partial=True, context={"request": request})
    ser.is_valid(raise_exception=True)
    ser.save()
    return ser.data


def find_nearby_drivers(lat, lon, search_radius=1000):
    """
    Core logic for finding nearby drivers based on passenger location.
    Fully extracted from views for modularity.
    """
    qs = DriverProfile.objects.filter(
        status="available",
        current_latitude__isnull=False,
        current_longitude__isnull=False,
    ).select_related("user")

    nearby = []
    for driver in qs:
        dist = calculate_distance(
            lat, lon, driver.current_latitude, driver.current_longitude
        )
        if dist <= search_radius:
            nearby.append({
                "driver_id": driver.id,
                "username": driver.user.username,
                "vehicle_number": driver.vehicle_number,
                "latitude": float(driver.current_latitude),
                "longitude": float(driver.current_longitude),
                "distance_meters": round(dist, 2),
                "last_updated": driver.last_location_update,
            })

    nearby.sort(key=lambda d: d["distance_meters"])
    return nearby


def get_passenger_ride_history(user, limit=20):
    """Return list of past rides for passenger."""
    qs = RideRequest.objects.filter(
        passenger=user,
        status__in=["completed", "cancelled_user", "cancelled_driver"]
    ).order_by("-requested_at")[:limit]

    return RideRequestSerializer(qs, many=True, context={"request": None}).data
