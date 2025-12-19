from asgiref.sync import async_to_sync
from rest_framework import status
from rest_framework.decorators import api_view, permission_classes
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from django.utils import timezone
from channels.layers import get_channel_layer

from drivers.models import DriverProfile
from .models import RideRequest
from .serializers import (
    RideRequestSerializer,
    RideRequestCreateSerializer,
    RideCancelSerializer
)

# Import from services layer
from services.matching import build_offers_for_ride, dispatch_next_offer
from realtime.notifications import notify_driver_event, notify_passenger_event


# @api_view(['GET'])
# def health_check(request):
#     """Health check endpoint for monitoring system status"""
#     health_status = {
#         'status': 'healthy',
#         'timestamp': timezone.now().isoformat(),
#         'services': {}
#     }

#     # Check database
#     try:
#         RideRequest.objects.count()
#         health_status['services']['database'] = 'healthy'
#     except Exception as e:
#         health_status['services']['database'] = f'unhealthy: {str(e)}'
#         health_status['status'] = 'unhealthy'

#     # Check Redis
#     try:
#         redis_client = redis.Redis(
#             host=os.getenv('REDIS_HOST', 'localhost'),
#             port=int(os.getenv('REDIS_PORT', 6379)),
#             db=0,
#             socket_timeout=5
#         )
#         redis_client.ping()
#         health_status['services']['redis'] = 'healthy'
#     except Exception as e:
#         health_status['services']['redis'] = f'unhealthy: {str(e)}'
#         health_status['status'] = 'unhealthy'

#     # Check channel layer
#     try:
#         channel_layer = get_channel_layer()
#         if channel_layer:
#             health_status['services']['channels'] = 'healthy'
#         else:
#             health_status['services']['channels'] = 'unhealthy: no channel layer'
#             health_status['status'] = 'unhealthy'
#     except Exception as e:
#         health_status['services']['channels'] = f'unhealthy: {str(e)}'
#         health_status['status'] = 'unhealthy'

#     # Check Celery (by checking if task is registered)
#     try:
#         from .tasks import expire_ride_offer_task
#         if expire_ride_offer_task:
#             health_status['services']['celery'] = 'healthy'
#         else:
#             health_status['services']['celery'] = 'unhealthy: task not found'
#             health_status['status'] = 'unhealthy'
#     except Exception as e:
#         health_status['services']['celery'] = f'unhealthy: {str(e)}'
#         health_status['status'] = 'unhealthy'

#     status_code = status.HTTP_200_OK if health_status['status'] == 'healthy' else status.HTTP_503_SERVICE_UNAVAILABLE
#     return Response(health_status, status=status_code)


# ==================== Passenger Ride APIs ====================

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def create_ride_request(request):
    """Create a new ride request (User clicks Book E-Rick)"""
    if request.user.role != 'user':
        return Response(
            {'error': 'Only passengers can create ride requests'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    # Check if user already has an active ride
    active_ride = RideRequest.objects.filter(
        passenger=request.user,
        status__in=['pending', 'accepted', 'in_progress']
    ).first()
    
    if active_ride:
        return Response(
            {'error': 'You already have an active ride request'},
            status=status.HTTP_400_BAD_REQUEST
        )
    
    serializer = RideRequestCreateSerializer(data=request.data)
    if serializer.is_valid():
        ride = serializer.save(passenger=request.user)

        # Daisy Chaining: Select possible drivers & send notifications sequentially
        offers = build_offers_for_ride(ride)
        if offers:
            dispatch_next_offer(ride)
        else:
            # No drivers within broadcast radius at time of request — notify passenger
            try:
                notify_passenger_event(
                    'no_drivers_available',
                    ride,
                    'No drivers found nearby. Please try again later.'
                )
            except Exception:
                import logging
                logging.getLogger(__name__).exception('Failed to notify passenger of no nearby drivers')
        driver_candidates = len(offers)
        response_message = (
            'Notifying nearby drivers...'
            if driver_candidates
            else 'No available drivers found nearby yet. We will keep searching.'
        )

        response_serializer = RideRequestSerializer(ride)
        return Response({
            **response_serializer.data,
            'message': response_message,
            'driver_candidates': driver_candidates,
            'sequential_notifications': driver_candidates > 0
        }, status=status.HTTP_201_CREATED)
    
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def get_current_ride(request):
    """
    Get passenger's current active ride (POLLING ENDPOINT)
    
    User app polls this every 3 seconds to check ride status
    Returns full driver details when ride is accepted
    """
    if request.user.role != 'user':
        return Response(
            {'error': 'Only passengers can access this endpoint'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    ride = RideRequest.objects.filter(
        passenger=request.user,
        status__in=['pending', 'accepted', 'no_drivers']
    ).select_related('driver__driver_profile').first()
    
    if not ride:
        return Response(
            {
                'has_active_ride': False,
                'message': 'No active ride found'
            },
            status=status.HTTP_200_OK
        )
    
    serializer = RideRequestSerializer(ride, context={'request': request})
    response_data = {
        'has_active_ride': True,
        'ride': serializer.data,
        'status': ride.status
    }
    
    # Add helpful messages based on status
    if ride.status == 'pending':
        response_data['message'] = 'Searching for nearby drivers...'
        response_data['driver_assigned'] = False
    elif ride.status == 'accepted':
        response_data['message'] = 'Driver is on the way!'
        response_data['driver_assigned'] = True
    elif ride.status == 'no_drivers':
        response_data['message'] = 'No drivers available at the moment. You can cancel and try again later.'
        response_data['driver_assigned'] = False
    
    return Response(response_data)


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def cancel_ride(request, ride_id):
    """
    Cancel ride by passenger
    
    Can be called manually by user or automatically by frontend
    after timeout (e.g., no driver found in 2 minutes)
    """
    try:
        ride = RideRequest.objects.get(id=ride_id, passenger=request.user)
    except RideRequest.DoesNotExist:
        return Response(
            {'error': 'Ride not found'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    # Can only cancel if not already completed or cancelled
    if ride.status in ['completed', 'cancelled_user', 'cancelled_driver']:
        return Response(
            {
                'error': 'Cannot cancel this ride',
                'message': f'Ride is already {ride.status}',
                'status': ride.status
            },
            status=status.HTTP_400_BAD_REQUEST
        )
    
    serializer = RideCancelSerializer(data=request.data)
    if serializer.is_valid():
        # Store original status to check if driver was assigned
        had_driver = ride.driver is not None

        ride.status = 'cancelled_user'
        ride.cancelled_at = timezone.now()
        ride.cancellation_reason = serializer.validated_data.get('reason', 'No reason provided')
        ride.save(update_fields=['status', 'cancelled_at', 'cancellation_reason'])

        # If ride was accepted, make driver available again
        if had_driver and hasattr(ride.driver, 'driver_profile'):
            ride.driver.driver_profile.status = 'available'
            ride.driver.driver_profile.save(update_fields=['status'])

        notified_driver_ids = set()
        if had_driver:
            notify_driver_event(
                'ride_cancelled',
                ride,
                ride.driver_id,
                'Passenger cancelled this ride.',
            )
            notified_driver_ids.add(ride.driver_id)

        # Also notify any listeners subscribed to the ride group (ride_<id>)
        try:
            channel_layer = get_channel_layer()
            if channel_layer is not None:
                async_to_sync(channel_layer.group_send)(
                    f'ride_{ride.id}',
                    {
                        'type': 'ride_cancelled',
                        'ride_id': ride.id,
                        'message': 'Passenger cancelled this ride.',
                    },
                )
        except Exception:
            import logging
            logging.getLogger(__name__).exception('Failed to notify ride group of cancellation')

        viewed_offer_driver_ids = ride.offers.filter(sent_at__isnull=False).values_list('driver_id', flat=True)
        for driver_id in viewed_offer_driver_ids:
            if driver_id in notified_driver_ids:
                continue
            notify_driver_event(
                'ride_cancelled',
                ride,
                driver_id,
                'Ride request cancelled before assignment.',
            )
            notified_driver_ids.add(driver_id)

        return Response({
            'success': True,
            'message': 'Ride cancelled successfully',
            'ride_id': ride.id,
            'was_assigned': had_driver,
            'cancelled_at': ride.cancelled_at
        })
    
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

# ------------------ for driver to be shifted -------------

@api_view(['POST'])
@permission_classes([IsAuthenticated])
def accept_ride(request, ride_id):
    """Accept a ride request that was offered to this driver."""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can accept rides'},
            status=status.HTTP_403_FORBIDDEN
        )

    try:
        driver_profile = request.user.driver_profile
    except DriverProfile.DoesNotExist:
        return Response(
            {'error': 'Driver profile not found'},
            status=status.HTTP_404_NOT_FOUND
        )

    if driver_profile.status != 'available':
        return Response(
            {
                'success': False,
                'error': 'driver_not_available',
                'message': 'Please set your status to available before accepting rides.'
            },
            status=status.HTTP_400_BAD_REQUEST
        )

    try:
        ride = RideRequest.objects.select_related('passenger').get(id=ride_id, status='pending')
    except RideRequest.DoesNotExist:
        return Response(
            {
                'success': False,
                'error': 'ride_not_available',
                'message': 'This ride was already handled or cancelled.',
                'ride_id': ride_id
            },
            status=status.HTTP_400_BAD_REQUEST
        )

    # Enforce ledger-based acceptance only if offers exist for this ride
    offer_qs = ride.offers.filter(driver=request.user)
    if offer_qs.exists():
        offer = offer_qs.filter(status='pending').order_by('order').first()
        if not offer:
            # Check if offer was expired due to timeout
            expired_offer = offer_qs.filter(status='expired').first()
            if expired_offer:
                return Response(
                    {
                        'success': False,
                        'error': 'offer_expired',
                        'message': 'This ride offer has timed out. Please wait for new ride requests.'
                    },
                    status=status.HTTP_410_GONE
                )
            return Response(
                {
                    'success': False,
                    'error': 'offer_not_found',
                    'message': 'This ride offer is no longer active for you.'
                },
                status=status.HTTP_400_BAD_REQUEST
            )
    else:
        offer = None  # Backwards compatibility for rides created pre-ledger rollout

    ride.driver = request.user
    ride.status = 'accepted'
    ride.accepted_at = timezone.now()
    ride.save(update_fields=['driver', 'status', 'accepted_at'])

    if offer:
        offer.status = 'accepted'
        offer.responded_at = timezone.now()
        offer.save(update_fields=['status', 'responded_at'])
        ride.offers.exclude(id=offer.id).filter(status='pending').update(
            status='expired',
            responded_at=timezone.now()
        )

    # No need to notify other drivers as sequential offers are sent one at a time
    try:
        ride.offers.filter(sent_at__isnull=False).exclude(driver=request.user).update(
            status='expired',
            responded_at=timezone.now()
        )
    except Exception:
        import logging
        logging.getLogger(__name__).exception('Failed to expire other offers for ride %s', ride.id)

    # Notify passenger that their ride was accepted
    notify_passenger_event(
        'ride_accepted',
        ride,
        'Your Ride has been Accepted! The Driver is on the way.',
    )

    driver_profile.status = 'busy'
    driver_profile.save(update_fields=['status'])

    serializer = RideRequestSerializer(ride)
    return Response({
        'success': True,
        'ride': serializer.data,
        'message': 'Ride Accepted Successfully! Navigate to pickup location.'
    })


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def reject_ride_offer(request, ride_id):
    """Allow drivers to reject a pending ride offer and trigger the next notification."""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can reject rides'},
            status=status.HTTP_403_FORBIDDEN
        )

    try:
        driver_profile = request.user.driver_profile
    except DriverProfile.DoesNotExist:
        return Response(
            {'error': 'Driver profile not found'},
            status=status.HTTP_404_NOT_FOUND
        )

    try:
        ride = RideRequest.objects.get(id=ride_id, status='pending')
    except RideRequest.DoesNotExist:
        return Response(
            {
                'success': False,
                'error': 'ride_not_available',
                'message': 'This ride was already handled or cancelled.'
            },
            status=status.HTTP_400_BAD_REQUEST
        )

    offer = ride.offers.filter(driver=request.user, status='pending').order_by('order').first()
    if not offer:
        return Response(
            {
                'success': False,
                'error': 'offer_not_found',
                'message': 'No active offer found for this ride.'
            },
            status=status.HTTP_400_BAD_REQUEST
        )

    offer.status = 'rejected'
    offer.responded_at = timezone.now()
    offer.save(update_fields=['status', 'responded_at'])

    dispatched = dispatch_next_offer(ride)
    if not dispatched and not ride.offers.filter(status='pending').exists():
        ride.status = 'no_drivers'
        ride.save(update_fields=['status'])
        # Notify passenger depending on whether any offers were actually sent.
        # If any offers were sent (sent_at not null) -> sequential-offers flow failed → send 'ride_expired'.
        # If no offers were ever sent -> there were no drivers nearby -> send 'no_drivers_available'.
        try:
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
        except Exception:
            import logging
            logging.getLogger(__name__).exception('Failed to notify passenger of no drivers available')

    return Response({
        'success': True,
        'ride_id': ride.id,
        'queued_next_driver': dispatched,
        'message': 'Offer declined. We will notify the next available driver.' if dispatched else 'No more drivers available for this ride.'
    })


# @api_view(['GET'])
# @permission_classes([IsAuthenticated])
# def driver_current_ride(request):
#     """Get driver's current active ride"""
#     if request.user.role != 'driver':
#         return Response(
#             {'error': 'Only drivers can access this endpoint'},
#             status=status.HTTP_403_FORBIDDEN
#         )
    
#     ride = RideRequest.objects.filter(
#         driver=request.user,
#         status='accepted'
#     ).first()
    
#     if not ride:
#         return Response(
#             {'message': 'No active ride found'},
#             status=status.HTTP_404_NOT_FOUND
#         )
    
#     serializer = RideRequestSerializer(ride)
#     return Response(serializer.data)


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def complete_ride(request, ride_id):
    """
    Complete a ride - CALLED BY DRIVER
    
    Driver taps "Complete Ride" button when passenger reaches destination
    Changes status: accepted → completed (No 'in_progress' status needed)
    Makes driver available for next ride
    """
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can complete rides'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    try:
        ride = RideRequest.objects.get(id=ride_id, driver=request.user, status='accepted')
    except RideRequest.DoesNotExist:
        return Response(
            {'error': 'Ride not found or not accepted by you'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    ride.status = 'completed'
    ride.completed_at = timezone.now()
    ride.save()
    
    # Update ride counts
    ride.passenger.completed_rides += 1
    ride.passenger.save()
    
    ride.driver.completed_rides += 1
    ride.driver.save()
    
    # Make driver available again
    ride.driver.driver_profile.status = 'available'
    ride.driver.driver_profile.save()
    # Notify passenger that the ride has been completed and notify ride group
    try:
        notify_passenger_event(
            'ride_completed',
            ride,
            'Your ride has been completed. Thank you for riding with us!',
        )
    except Exception:
        import logging
        logging.getLogger(__name__).exception('Failed to notify passenger of ride completion')

    # Also notify any listeners subscribed to the ride group (ride_<id>)
    try:
        channel_layer = get_channel_layer()
        if channel_layer is not None:
            async_to_sync(channel_layer.group_send)(
                f'ride_{ride.id}',
                {
                    'type': 'ride_completed',
                    'ride_id': ride.id,
                    'message': 'Ride completed by driver',
                },
            )
    except Exception:
        import logging
        logging.getLogger(__name__).exception('Failed to notify ride group of completion')
    
    return Response({
        'success': True,
        'message': 'Ride completed successfully',
        'ride_id': ride.id,
        'status': 'completed',
        'completed_at': ride.completed_at,
        'driver_status': 'available'
    })


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def driver_cancel_ride(request, ride_id):
    """Cancel ride by driver - marks ride as cancelled_driver"""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can cancel rides'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    try:
        ride = RideRequest.objects.get(
            id=ride_id,
            driver=request.user,
            status='accepted'
        )
    except RideRequest.DoesNotExist:
        return Response(
            {'error': 'Ride not found or not accepted by you'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    serializer = RideCancelSerializer(data=request.data)
    if serializer.is_valid():
        # Mark ride as cancelled by driver
        ride.status = 'cancelled_driver'
        ride.cancelled_at = timezone.now()
        ride.cancellation_reason = serializer.validated_data.get('reason', 'Cancelled by driver')
        ride.save()
        
        # Make driver available again
        request.user.driver_profile.status = 'available'
        request.user.driver_profile.save()
        
        # Notify passenger via websocket that driver cancelled
        try:
            notify_passenger_event(
                'ride_cancelled',
                ride,
                'Driver cancelled the ride. Please request again.',
            )
        except Exception:
            # best-effort - don't fail the API if WS notify fails
            import logging
            logging.getLogger(__name__).exception('Failed to notify passenger of driver cancellation')
        # Also notify any listeners subscribed to the ride group (ride_<id>)
        try:
            channel_layer = get_channel_layer()
            if channel_layer is not None:
                async_to_sync(channel_layer.group_send)(
                    f'ride_{ride.id}',
                    {
                        'type': 'ride_cancelled',
                        'ride_id': ride.id,
                        'message': 'Driver cancelled the ride. Please request again.',
                    },
                )
        except Exception:
            import logging
            logging.getLogger(__name__).exception('Failed to notify ride group of driver cancellation')
        
        return Response({
            'success': True,
            'message': 'Ride cancelled successfully',
            'ride_id': ride.id,
            'status': 'cancelled_driver',
            'cancelled_at': ride.cancelled_at
        })
    
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
