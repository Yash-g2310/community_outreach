"""
DEPRECATED: This module is kept for backward compatibility.
Use realtime.notifications instead.

All notification functions have been moved to the realtime app.
"""

from realtime.notifications import (
    build_offers_for_ride,
    dispatch_next_offer,
    expire_offer_and_dispatch,
    notify_driver_event,
    notify_passenger_event,
)

__all__ = [
    "build_offers_for_ride",
    "dispatch_next_offer",
    "expire_offer_and_dispatch",
    "notify_driver_event",
    "notify_passenger_event",
]
