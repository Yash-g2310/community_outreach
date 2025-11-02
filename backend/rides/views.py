from rest_framework import status, generics, permissions
from rest_framework.decorators import api_view, permission_classes
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from django.utils import timezone
from django.db.models import Q
from math import radians, cos, sin, asin, sqrt
from .models import User, DriverProfile, RideRequest
from .serializers import (
    UserSerializer, DriverProfileSerializer, RideRequestSerializer,
    RideRequestCreateSerializer, LocationUpdateSerializer,
    DriverStatusSerializer, RideCancelSerializer
)


def calculate_distance(lat1, lon1, lat2, lon2):
    """Calculate distance between two points in meters using Haversine formula"""
    # Convert decimal degrees to radians
    lat1, lon1, lat2, lon2 = map(radians, [float(lat1), float(lon1), float(lat2), float(lon2)])
    
    # Haversine formula
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = sin(dlat/2)**2 + cos(lat1) * cos(lat2) * sin(dlon/2)**2
    c = 2 * asin(sqrt(a))
    
    # Radius of earth in meters
    r = 6371000
    return c * r

@api_view(['GET', 'POST', 'PUT', 'PATCH'])
@permission_classes([IsAuthenticated])
def user_profile(request):
    """Get or update user profile (including profile picture)"""
    user = request.user
    
    if request.method == 'GET':
        serializer = UserSerializer(user, context={'request': request})
        return Response(serializer.data)
    
    elif request.method in ['POST', 'PUT', 'PATCH']:
        # Handle both JSON and multipart/form-data
        serializer = UserSerializer(user, data=request.data, partial=True, context={'request': request})
        if serializer.is_valid():
            serializer.save()
            return Response(serializer.data)
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

@api_view(['POST', 'GET'])
@permission_classes([IsAuthenticated])
def driver_profile(request):
    """Create or get driver profile"""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can access this endpoint'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    if request.method == 'GET':
        try:
            profile = request.user.driver_profile
            serializer = DriverProfileSerializer(profile, context={'request': request})
            return Response(serializer.data)
        except DriverProfile.DoesNotExist:
            return Response(
                {'error': 'Driver profile not found. Please create one.'},
                status=status.HTTP_404_NOT_FOUND
            )
    
    elif request.method == 'POST':
        # Create or update driver profile
        profile, created = DriverProfile.objects.get_or_create(
            user=request.user,
            defaults={'vehicle_number': request.data.get('vehicle_number')}
        )
        
        if not created:
            # Update existing profile
            profile.vehicle_number = request.data.get('vehicle_number', profile.vehicle_number)
            profile.save()
        
        serializer = DriverProfileSerializer(profile, context={'request': request})
        return Response(serializer.data, status=status.HTTP_201_CREATED if created else status.HTTP_200_OK)


@api_view(['GET', 'PUT', 'PATCH'])
@permission_classes([IsAuthenticated])
def update_driver_status(request):
    """Get or update driver availability status"""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can access this endpoint'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    try:
        profile = request.user.driver_profile
    except DriverProfile.DoesNotExist:
        return Response(
            {'error': 'Driver profile not found'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    if request.method == 'GET':
        return Response({
            'status': profile.status,
            'vehicle_number': profile.vehicle_number,
            'current_latitude': profile.current_latitude,
            'current_longitude': profile.current_longitude,
            'last_location_update': profile.last_location_update
        })
    
    # PUT or PATCH request
    serializer = DriverStatusSerializer(data=request.data)
    if serializer.is_valid():
        profile.status = serializer.validated_data['status']
        profile.save()
        
        return Response({
            'status': profile.status,
            'message': f'You are now {profile.status}'
        })
    
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


@api_view(['GET', 'POST', 'PUT', 'PATCH'])
@permission_classes([IsAuthenticated])
def update_driver_location(request):
    """Get or update driver's current location"""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can access this endpoint'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    try:
        profile = request.user.driver_profile
    except DriverProfile.DoesNotExist:
        return Response(
            {'error': 'Driver profile not found'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    if request.method == 'GET':
        # Get current driver location
        return Response({
            'latitude': float(profile.current_latitude) if profile.current_latitude else None,
            'longitude': float(profile.current_longitude) if profile.current_longitude else None,
            'last_updated': profile.last_location_update,
            'status': profile.status,
            'vehicle_number': profile.vehicle_number
        })
    
    # POST, PUT, or PATCH - Update location
    serializer = LocationUpdateSerializer(data=request.data)
    if serializer.is_valid():
        profile.current_latitude = serializer.validated_data['latitude']
        profile.current_longitude = serializer.validated_data['longitude']
        profile.last_location_update = timezone.now()
        profile.save()
        
        return Response({
            'message': 'Location updated successfully',
            'latitude': float(profile.current_latitude),
            'longitude': float(profile.current_longitude),
            'last_updated': profile.last_location_update,
            'status': profile.status
        })
    
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def nearby_drivers_for_passenger(request):
    """
    Get nearby available drivers for passenger home screen map
    Uses POST to keep location data secure in request body
    """
    if request.user.role != 'user':
        return Response(
            {'error': 'Only passengers can access this endpoint'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    serializer = LocationUpdateSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
    
    passenger_lat = serializer.validated_data['latitude']
    passenger_lon = serializer.validated_data['longitude']
    
    # Default search radius: 5km
    search_radius = request.data.get('radius', 5000)
    
    # Get all available drivers with location
    available_drivers = DriverProfile.objects.filter(
        status='available',
        current_latitude__isnull=False,
        current_longitude__isnull=False
    ).select_related('user')
    
    # Calculate distance and filter
    nearby = []
    for driver in available_drivers:
        distance = calculate_distance(
            passenger_lat, passenger_lon,
            driver.current_latitude, driver.current_longitude
        )
        
        if distance <= search_radius:
            nearby.append({
                'driver_id': driver.id,
                'username': driver.user.username,
                'vehicle_number': driver.vehicle_number,
                'latitude': float(driver.current_latitude),
                'longitude': float(driver.current_longitude),
                'distance_meters': round(distance, 2),
                'last_updated': driver.last_location_update
            })
    
    # Sort by distance
    nearby.sort(key=lambda x: x['distance_meters'])
    
    return Response({
        'count': len(nearby),
        'drivers': nearby,
        'search_radius_meters': search_radius
    })


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
        
        # ✅ No WebSocket - Drivers will discover via polling
        response_serializer = RideRequestSerializer(ride)
        return Response({
            **response_serializer.data,
            'message': 'Finding nearby drivers...'
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
        status__in=['pending', 'accepted']
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
        ride.save()
        
        # If ride was accepted, make driver available again
        if had_driver and hasattr(ride.driver, 'driver_profile'):
            ride.driver.driver_profile.status = 'available'
            ride.driver.driver_profile.save()
        
        return Response({
            'success': True,
            'message': 'Ride cancelled successfully',
            'ride_id': ride.id,
            'was_assigned': had_driver,
            'cancelled_at': ride.cancelled_at
        })
    
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def ride_history(request):
    """Get passenger's ride history"""
    if request.user.role != 'user':
        return Response(
            {'error': 'Only passengers can access ride history'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    rides = RideRequest.objects.filter(
        passenger=request.user,
        status__in=['completed', 'cancelled_user', 'cancelled_driver']
    ).order_by('-requested_at')[:20]  # Last 20 rides
    
    serializer = RideRequestSerializer(rides, many=True, context={'request': request})
    return Response({
        'rides': serializer.data,
        'count': len(serializer.data)
    })


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def driver_ride_history(request):
    """Get driver's ride history (completed and cancelled rides)"""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can access ride history'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    rides = RideRequest.objects.filter(
        driver=request.user,
        status__in=['completed', 'cancelled_user', 'cancelled_driver']
    ).order_by('-requested_at')[:20]  # Last 20 rides
    
    serializer = RideRequestSerializer(rides, many=True, context={'request': request})
    return Response({
        'rides': serializer.data,
        'count': len(serializer.data)
    })


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def nearby_rides(request):
    """
    Get nearby pending ride requests for drivers
    
    Driver sends their current location and gets rides within 500m radius
    Request body: {"latitude": 28.5355, "longitude": 77.3910}
    """
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can access this endpoint'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    try:
        driver_profile = request.user.driver_profile
    except DriverProfile.DoesNotExist:
        return Response(
            {'error': 'Driver profile not found'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    # Only show rides if driver is available
    if driver_profile.status != 'available':
        return Response({
            'rides': [],
            'count': 0,
            'message': 'You must be available to see nearby rides'
        })
    
    # Validate and get driver's current location from request body
    serializer = LocationUpdateSerializer(data=request.data)
    if not serializer.is_valid():
        return Response(
            {'error': 'Please provide latitude and longitude in request body'},
            status=status.HTTP_400_BAD_REQUEST
        )
    
    driver_lat = serializer.validated_data['latitude']
    driver_lon = serializer.validated_data['longitude']
    
    # Get all pending ride requests
    pending_rides = RideRequest.objects.filter(
        status='pending'
    ).select_related('passenger')  # Optimize query
    
    # Calculate distance and filter rides within broadcast radius (500m)
    nearby_rides_data = []
    for ride in pending_rides:
        # Calculate distance from driver to passenger pickup location
        distance = calculate_distance(
            driver_lat, driver_lon,
            ride.pickup_latitude, ride.pickup_longitude
        )
        
        # Only include rides within the broadcast radius (default 500m)
        if distance <= ride.broadcast_radius:
            ride_data = RideRequestSerializer(ride).data
            ride_data['distance_from_driver'] = round(distance)  # Add distance in meters
            nearby_rides_data.append(ride_data)
    
    # Sort rides by distance (closest first)
    nearby_rides_data.sort(key=lambda x: x['distance_from_driver'])
    
    return Response({
        'rides': nearby_rides_data,
        'count': len(nearby_rides_data),
        'broadcast_radius': 500,  # Show the search radius
        'driver_location': {
            'latitude': float(driver_lat),
            'longitude': float(driver_lon)
        }
    })


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def accept_ride(request, ride_id):
    """
    Accept a ride request (first-come-first-served)
    
    Handles race conditions when multiple drivers try to accept same ride
    """
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
    
    # Check if driver is available
    if driver_profile.status != 'available':
        return Response(
            {
                'success': False,
                'error': 'You must be available to accept rides',
                'message': 'Please set your status to available first'
            },
            status=status.HTTP_400_BAD_REQUEST
        )
    
    # Try to get ride with status='pending' (race condition protection)
    try:
        ride = RideRequest.objects.get(id=ride_id, status='pending')
    except RideRequest.DoesNotExist:
        # Ride doesn't exist or already accepted/cancelled
        return Response(
            {
                'success': False,
                'error': 'ride_not_available',
                'message': 'This ride has already been accepted by another driver or cancelled',
                'ride_id': ride_id
            },
            status=status.HTTP_400_BAD_REQUEST
        )
    
    # Accept the ride (atomic operation)
    ride.driver = request.user
    ride.status = 'accepted'
    ride.accepted_at = timezone.now()
    ride.save()
    
    # Update driver status to busy
    driver_profile.status = 'busy'
    driver_profile.save()
    
    # ✅ Success - Driver got the ride
    serializer = RideRequestSerializer(ride)
    return Response({
        'success': True,
        'ride': serializer.data,
        'message': 'Ride accepted successfully! Navigate to pickup location.'
    })


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def driver_current_ride(request):
    """Get driver's current active ride"""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can access this endpoint'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    ride = RideRequest.objects.filter(
        driver=request.user,
        status='accepted'
    ).first()
    
    if not ride:
        return Response(
            {'message': 'No active ride found'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    serializer = RideRequestSerializer(ride)
    return Response(serializer.data)


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
        
        return Response({
            'success': True,
            'message': 'Ride cancelled successfully',
            'ride_id': ride.id,
            'status': 'cancelled_driver',
            'cancelled_at': ride.cancelled_at
        })
    
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
