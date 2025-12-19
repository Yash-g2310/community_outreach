"""
Ride management service - Core ride lifecycle operations.

This module handles:
    - Creating ride requests
    - Accepting/rejecting rides
    - Completing rides
    - Cancelling rides
    - Querying ride status
"""

from .ride_lifecycle import (
    create_ride_request,
    accept_ride,
    reject_ride_offer,
    complete_ride,
    cancel_ride_by_passenger,
    cancel_ride_by_driver,
    get_current_passenger_ride,
    get_current_driver_ride,
)

from .exceptions import (
    RideNotFoundError,
    RideNotAvailableError,
    OfferExpiredError,
    OfferNotFoundError,
    DriverNotAvailableError,
    ActiveRideExistsError,
)

__all__ = [
    # Lifecycle operations
    "create_ride_request",
    "accept_ride",
    "reject_ride_offer",
    "complete_ride",
    "cancel_ride_by_passenger",
    "cancel_ride_by_driver",
    "get_current_passenger_ride",
    "get_current_driver_ride",
    # Exceptions
    "RideNotFoundError",
    "RideNotAvailableError",
    "OfferExpiredError",
    "OfferNotFoundError",
    "DriverNotAvailableError",
    "ActiveRideExistsError",
]
