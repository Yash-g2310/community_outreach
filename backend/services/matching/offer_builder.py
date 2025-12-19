"""
Build ordered driver offer queues for rides.

Uses driver locations and distances to create a prioritized list of drivers
to offer the ride to (closest first).
"""

import logging
from typing import List

from drivers.models import DriverProfile
from rides.models import RideRequest, RideOffer
from common.utils import calculate_distance

logger = logging.getLogger(__name__)


def build_offers_for_ride(ride: RideRequest) -> List[RideOffer]:
    """
    Build the ordered RideOffer list (queue) for one ride.
    
    Args:
        ride: RideRequest instance to build offers for
    
    Returns:
        List of RideOffer instances sorted by distance (closest first)
    """
    # Fetch currently available drivers with stored live location
    available_drivers = (
        DriverProfile.objects.select_related("user")
        .filter(
            status="available",
            current_latitude__isnull=False,
            current_longitude__isnull=False,
        )
    )

    # Compute distance from ride pickup for each driver
    candidates: List[tuple] = []
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

    # Sort closest → farthest
    candidates.sort(key=lambda item: item[1])

    # Clear old offers to avoid stale/outdated queue
    ride.offers.all().delete()

    # Insert updated queue (ordered RideOffer rows)
    offers: List[RideOffer] = []
    for order, (profile, _) in enumerate(candidates):
        offer = RideOffer.objects.create(
            ride=ride,
            driver=profile.user,
            order=order,
            status="pending",
        )
        offers.append(offer)

    logger.info(
        "Built %d offers for ride %s (radius=%sm)",
        len(offers), ride.id, ride.broadcast_radius
    )

    return offers
