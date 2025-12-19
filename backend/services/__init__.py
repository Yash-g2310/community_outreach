"""
Services package - Business logic layer.

This package contains all business logic services that operate on Django models
but are decoupled from the HTTP/WebSocket layer.

Modules:
    - ride_management: Core ride lifecycle operations
    - matching: Driver matching and offer dispatch
"""

# Expose commonly used functions at package level
from .matching import (
    build_offers_for_ride,
    dispatch_next_offer,
    expire_offer_and_dispatch,
)
from .ride_management import (
    create_ride_request,
    accept_ride,
    reject_ride_offer,
    cancel_ride_by_passenger,
    cancel_ride_by_driver,
    complete_ride,
    get_current_passenger_ride,
    get_current_driver_ride,
    RideNotFoundError,
    RideNotAvailableError,
    OfferExpiredError,
    OfferNotFoundError,
    DriverNotAvailableError,
    ActiveRideExistsError,
)

__all__ = [
    # Matching
    "build_offers_for_ride",
    "dispatch_next_offer",
    "expire_offer_and_dispatch",
    # Ride management
    "create_ride_request",
    "accept_ride",
    "reject_ride_offer",
    "cancel_ride_by_passenger",
    "cancel_ride_by_driver",
    "complete_ride",
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
