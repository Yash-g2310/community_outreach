"""
DEPRECATED: This module is kept for backward compatibility.
Use realtime.consumers and realtime.notifications instead.

All WebSocket consumers have been moved to the realtime app:
    - realtime.consumers.DriverConsumer
    - realtime.consumers.PassengerConsumer
    - realtime.consumers.RideConsumer

Notification helpers have been moved to:
    - realtime.notifications
"""

# Re-export for backward compatibility
from realtime.consumers import (
    DriverConsumer,
    PassengerConsumer,
    RideConsumer,
    ACTIVE_PASSENGERS,
)
from realtime.notifications import (
    notify_nearby_passengers_async,
    notify_nearby_passengers_sync,
)

# Legacy alias for old code that might reference AppConsumer
# The new architecture splits this into role-specific consumers
AppConsumer = RideConsumer

__all__ = [
    "DriverConsumer",
    "PassengerConsumer",
    "RideConsumer",
    "AppConsumer",
    "ACTIVE_PASSENGERS",
    "notify_nearby_passengers_async",
    "notify_nearby_passengers_sync",
]