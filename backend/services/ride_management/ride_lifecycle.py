"""
Core ride lifecycle operations.

This module contains all the business logic for managing rides,
extracted from the views layer for better testability and reuse.
"""

import logging
from typing import Optional, Dict, Any, Tuple
from dataclasses import dataclass

from django.db import transaction
from django.utils import timezone
from channels.layers import get_channel_layer
from asgiref.sync import async_to_sync

from rides.models import RideRequest, RideOffer
from drivers.models import DriverProfile
from .exceptions import (
    RideNotFoundError,
    RideNotAvailableError,
    OfferExpiredError,
    OfferNotFoundError,
    DriverNotAvailableError,
    ActiveRideExistsError,
)

logger = logging.getLogger(__name__)


@dataclass
class RideResult:
    """Result object for ride operations."""
    success: bool
    ride: Optional[RideRequest] = None
    message: str = ""
    error_code: Optional[str] = None
    extra: Optional[Dict[str, Any]] = None


# ===================== Passenger Operations =====================

def check_active_ride(user) -> Optional[RideRequest]:
    """Check if user has an active ride."""
    return RideRequest.objects.filter(
        passenger=user,
        status__in=['pending', 'accepted', 'in_progress']
    ).first()


@transaction.atomic
def create_ride_request(
    passenger,
    pickup_latitude: float,
    pickup_longitude: float,
    pickup_address: str = "",
    dropoff_address: str = "",
    number_of_passengers: int = 1,
    broadcast_radius: int = 1000,
) -> RideResult:
    """
    Create a new ride request and dispatch offers to nearby drivers.
    
    Args:
        passenger: User model instance (passenger)
        pickup_latitude: Pickup location latitude
        pickup_longitude: Pickup location longitude
        pickup_address: Human-readable pickup address
        dropoff_address: Human-readable dropoff address
        number_of_passengers: Number of passengers
        broadcast_radius: Search radius for drivers in meters
    
    Returns:
        RideResult with the created ride
    
    Raises:
        ActiveRideExistsError: If passenger already has an active ride
    """
    # Check for existing active ride
    existing = check_active_ride(passenger)
    if existing:
        raise ActiveRideExistsError("You already have an active ride request")
    
    # Create the ride
    ride = RideRequest.objects.create(
        passenger=passenger,
        pickup_latitude=pickup_latitude,
        pickup_longitude=pickup_longitude,
        pickup_address=pickup_address,
        dropoff_address=dropoff_address,
        number_of_passengers=number_of_passengers,
        broadcast_radius=broadcast_radius,
        status='pending',
    )
    
    # Build and dispatch offers
    from services.matching import build_offers_for_ride, dispatch_next_offer
    
    offers = build_offers_for_ride(ride)
    
    if offers:
        dispatch_next_offer(ride)
        message = "Notifying nearby drivers..."
    else:
        # No drivers available
        from realtime.notifications import notify_passenger_event
        notify_passenger_event(
            'no_drivers_available',
            ride,
            'No drivers found nearby. Please try again later.'
        )
        message = "No available drivers found nearby yet."
    
    return RideResult(
        success=True,
        ride=ride,
        message=message,
        extra={"driver_candidates": len(offers)}
    )


def get_current_passenger_ride(passenger) -> Optional[RideRequest]:
    """Get passenger's current active ride."""
    return RideRequest.objects.filter(
        passenger=passenger,
        status__in=['pending', 'accepted', 'no_drivers']
    ).select_related('driver__driver_profile').first()


@transaction.atomic
def cancel_ride_by_passenger(
    passenger,
    ride_id: int,
    reason: str = "No reason provided"
) -> RideResult:
    """
    Cancel a ride by passenger.
    
    Args:
        passenger: User model instance
        ride_id: ID of the ride to cancel
        reason: Cancellation reason
    
    Returns:
        RideResult with cancellation status
    """
    try:
        ride = RideRequest.objects.get(id=ride_id, passenger=passenger)
    except RideRequest.DoesNotExist:
        raise RideNotFoundError("Ride not found")
    
    if ride.status in ['completed', 'cancelled_user', 'cancelled_driver']:
        raise RideNotAvailableError(f"Cannot cancel - ride is already {ride.status}")
    
    had_driver = ride.driver is not None
    
    # Update ride
    ride.status = 'cancelled_user'
    ride.cancelled_at = timezone.now()
    ride.cancellation_reason = reason
    ride.save(update_fields=['status', 'cancelled_at', 'cancellation_reason'])
    
    # Restore driver availability
    notified_driver_ids = set()
    if had_driver:
        try:
            ride.driver.driver_profile.status = 'available'
            ride.driver.driver_profile.save(update_fields=['status'])
        except Exception:
            logger.exception("Failed to restore driver availability")
        
        # Notify assigned driver
        from realtime.notifications import notify_driver_event
        notify_driver_event('ride_cancelled', ride, ride.driver_id, 'Passenger cancelled this ride.')
        notified_driver_ids.add(ride.driver_id)
    
    # Notify ride group
    _notify_ride_group(ride, 'ride_cancelled', 'Passenger cancelled this ride.')
    
    # Notify other drivers who saw the offer
    from realtime.notifications import notify_driver_event
    viewed_offer_driver_ids = ride.offers.filter(
        sent_at__isnull=False
    ).values_list('driver_id', flat=True)
    
    for driver_id in viewed_offer_driver_ids:
        if driver_id not in notified_driver_ids:
            notify_driver_event('ride_cancelled', ride, driver_id, 'Ride request cancelled.')
            notified_driver_ids.add(driver_id)
    
    return RideResult(
        success=True,
        ride=ride,
        message="Ride cancelled successfully",
        extra={"was_assigned": had_driver}
    )


# ===================== Driver Operations =====================

@transaction.atomic
def accept_ride(driver, ride_id: int) -> RideResult:
    """
    Accept a ride request that was offered to this driver.
    
    Args:
        driver: User model instance (driver)
        ride_id: ID of the ride to accept
    
    Returns:
        RideResult with the accepted ride
    """
    # Validate driver profile
    try:
        driver_profile = driver.driver_profile
    except DriverProfile.DoesNotExist:
        raise RideNotFoundError("Driver profile not found")
    
    if driver_profile.status != 'available':
        raise DriverNotAvailableError("Please set your status to available before accepting rides")
    
    # Get the ride
    try:
        ride = RideRequest.objects.select_related('passenger').get(id=ride_id, status='pending')
    except RideRequest.DoesNotExist:
        raise RideNotAvailableError("This ride was already handled or cancelled")
    
    # Check offer status
    offer_qs = ride.offers.filter(driver=driver)
    offer = None
    
    if offer_qs.exists():
        offer = offer_qs.filter(status='pending').order_by('order').first()
        if not offer:
            expired_offer = offer_qs.filter(status='expired').first()
            if expired_offer:
                raise OfferExpiredError("This ride offer has timed out")
            raise OfferNotFoundError("This ride offer is no longer active for you")
    
    # Accept the ride
    ride.driver = driver
    ride.status = 'accepted'
    ride.accepted_at = timezone.now()
    ride.save(update_fields=['driver', 'status', 'accepted_at'])
    
    # Update offer status
    if offer:
        offer.status = 'accepted'
        offer.responded_at = timezone.now()
        offer.save(update_fields=['status', 'responded_at'])
        
        # Expire other pending offers
        ride.offers.exclude(id=offer.id).filter(status='pending').update(
            status='expired',
            responded_at=timezone.now()
        )
    
    # Notify passenger
    from realtime.notifications import notify_passenger_event
    notify_passenger_event(
        'ride_accepted',
        ride,
        'Your Ride has been Accepted! The Driver is on the way.'
    )
    
    # Update driver status
    driver_profile.status = 'busy'
    driver_profile.save(update_fields=['status'])
    
    return RideResult(
        success=True,
        ride=ride,
        message="Ride Accepted Successfully! Navigate to pickup location."
    )


@transaction.atomic
def reject_ride_offer(driver, ride_id: int) -> RideResult:
    """
    Reject a pending ride offer and trigger the next notification.
    
    Args:
        driver: User model instance (driver)
        ride_id: ID of the ride to reject
    
    Returns:
        RideResult with rejection status
    """
    try:
        ride = RideRequest.objects.get(id=ride_id, status='pending')
    except RideRequest.DoesNotExist:
        raise RideNotAvailableError("This ride was already handled or cancelled")
    
    offer = ride.offers.filter(driver=driver, status='pending').order_by('order').first()
    if not offer:
        raise OfferNotFoundError("No active offer found for this ride")
    
    # Mark offer as rejected
    offer.status = 'rejected'
    offer.responded_at = timezone.now()
    offer.save(update_fields=['status', 'responded_at'])
    
    # Dispatch next offer
    from services.matching import dispatch_next_offer
    dispatched = dispatch_next_offer(ride)
    
    if not dispatched and not ride.offers.filter(status='pending').exists():
        # No more drivers available
        ride.status = 'no_drivers'
        ride.save(update_fields=['status'])
        
        from realtime.notifications import notify_passenger_event
        sent_offers_exist = ride.offers.filter(sent_at__isnull=False).exists()
        
        if sent_offers_exist:
            notify_passenger_event(
                'ride_expired',
                ride,
                'No drivers accepted your ride request. Please try again later.'
            )
        else:
            notify_passenger_event(
                'no_drivers_available',
                ride,
                'No drivers available nearby. Please try again later.'
            )
    
    return RideResult(
        success=True,
        ride=ride,
        message="Offer declined." + (" We will notify the next available driver." if dispatched else ""),
        extra={"queued_next_driver": dispatched}
    )


@transaction.atomic
def complete_ride(driver, ride_id: int) -> RideResult:
    """
    Complete a ride - called by driver when passenger reaches destination.
    
    Args:
        driver: User model instance (driver)
        ride_id: ID of the ride to complete
    
    Returns:
        RideResult with completion status
    """
    try:
        ride = RideRequest.objects.get(id=ride_id, driver=driver, status='accepted')
    except RideRequest.DoesNotExist:
        raise RideNotFoundError("Ride not found or not accepted by you")
    
    # Complete the ride
    ride.status = 'completed'
    ride.completed_at = timezone.now()
    ride.save(update_fields=['status', 'completed_at'])
    
    # Update ride counts
    ride.passenger.completed_rides += 1
    ride.passenger.save(update_fields=['completed_rides'])
    
    ride.driver.completed_rides += 1
    ride.driver.save(update_fields=['completed_rides'])
    
    # Make driver available
    driver.driver_profile.status = 'available'
    driver.driver_profile.save(update_fields=['status'])
    
    # Notify passenger
    from realtime.notifications import notify_passenger_event
    notify_passenger_event(
        'ride_completed',
        ride,
        'Your ride has been completed. Thank you for riding with us!'
    )
    
    # Notify ride group
    _notify_ride_group(ride, 'ride_completed', 'Ride completed by driver')
    
    return RideResult(
        success=True,
        ride=ride,
        message="Ride completed successfully"
    )


@transaction.atomic
def cancel_ride_by_driver(driver, ride_id: int, reason: str = "Cancelled by driver") -> RideResult:
    """
    Cancel a ride by driver.
    
    Args:
        driver: User model instance (driver)
        ride_id: ID of the ride to cancel
        reason: Cancellation reason
    
    Returns:
        RideResult with cancellation status
    """
    try:
        ride = RideRequest.objects.get(id=ride_id, driver=driver, status='accepted')
    except RideRequest.DoesNotExist:
        raise RideNotFoundError("Ride not found or not accepted by you")
    
    # Cancel the ride
    ride.status = 'cancelled_driver'
    ride.cancelled_at = timezone.now()
    ride.cancellation_reason = reason
    ride.save(update_fields=['status', 'cancelled_at', 'cancellation_reason'])
    
    # Make driver available
    driver.driver_profile.status = 'available'
    driver.driver_profile.save(update_fields=['status'])
    
    # Notify passenger
    from realtime.notifications import notify_passenger_event
    notify_passenger_event(
        'ride_cancelled',
        ride,
        'Driver cancelled the ride. Please request again.'
    )
    
    # Notify ride group
    _notify_ride_group(ride, 'ride_cancelled', 'Driver cancelled the ride.')
    
    return RideResult(
        success=True,
        ride=ride,
        message="Ride cancelled successfully"
    )


def get_current_driver_ride(driver) -> Optional[RideRequest]:
    """Get driver's current active ride."""
    return RideRequest.objects.filter(
        driver=driver,
        status='accepted'
    ).select_related('passenger').first()


# ===================== Helper Functions =====================

def _notify_ride_group(ride: RideRequest, event_type: str, message: str):
    """Send notification to all participants in a ride group."""
    try:
        channel_layer = get_channel_layer()
        if channel_layer:
            async_to_sync(channel_layer.group_send)(
                f'ride_{ride.id}',
                {
                    'type': event_type,
                    'ride_id': ride.id,
                    'message': message,
                }
            )
    except Exception:
        logger.exception("Failed to notify ride group for ride %s", ride.id)
