"""Custom exceptions for ride management."""


class RideNotFoundError(Exception):
    """Raised when a ride cannot be found."""
    pass


class RideNotAvailableError(Exception):
    """Raised when a ride is not in an available state for the operation."""
    pass


class OfferExpiredError(Exception):
    """Raised when a ride offer has expired."""
    pass


class OfferNotFoundError(Exception):
    """Raised when a ride offer cannot be found."""
    pass


class DriverNotAvailableError(Exception):
    """Raised when driver is not available to accept rides."""
    pass


class ActiveRideExistsError(Exception):
    """Raised when user already has an active ride."""
    pass
