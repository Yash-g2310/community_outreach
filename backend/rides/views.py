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

@api_view(['GET', 'PUT'])
@permission_classes([IsAuthenticated])
def user_profile(request):
    """Get or update user profile"""
    user = request.user
    
    if request.method == 'GET':
        serializer = UserSerializer(user)
        return Response(serializer.data)
    
    elif request.method == 'PUT':
        serializer = UserSerializer(user, data=request.data, partial=True)
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
            serializer = DriverProfileSerializer(profile)
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
        
        serializer = DriverProfileSerializer(profile)
        return Response(serializer.data, status=status.HTTP_201_CREATED if created else status.HTTP_200_OK)


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def update_driver_status(request):
    """Toggle driver availability status"""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can update status'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    try:
        profile = request.user.driver_profile
    except DriverProfile.DoesNotExist:
        return Response(
            {'error': 'Driver profile not found'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    serializer = DriverStatusSerializer(data=request.data)
    if serializer.is_valid():
        profile.status = serializer.validated_data['status']
        profile.save()
        
        return Response({
            'status': profile.status,
            'message': f'You are now {profile.status}'
        })
    
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def update_driver_location(request):
    """Update driver's current location"""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can update location'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    try:
        profile = request.user.driver_profile
    except DriverProfile.DoesNotExist:
        return Response(
            {'error': 'Driver profile not found'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    serializer = LocationUpdateSerializer(data=request.data)
    if serializer.is_valid():
        profile.current_latitude = serializer.validated_data['latitude']
        profile.current_longitude = serializer.validated_data['longitude']
        profile.last_location_update = timezone.now()
        profile.save()
        
        return Response({
            'message': 'Location updated successfully',
            'latitude': profile.current_latitude,
            'longitude': profile.current_longitude
        })
    
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


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
        
        # TODO: Broadcast to nearby drivers via WebSocket
        # For now, return success response
        
        response_serializer = RideRequestSerializer(ride)
        return Response({
            **response_serializer.data,
            'message': 'Finding nearby drivers...'
        }, status=status.HTTP_201_CREATED)
    
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def get_current_ride(request):
    """Get passenger's current active ride"""
    if request.user.role != 'user':
        return Response(
            {'error': 'Only passengers can access this endpoint'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    ride = RideRequest.objects.filter(
        passenger=request.user,
        status__in=['pending', 'accepted', 'in_progress']
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
def cancel_ride(request, ride_id):
    """Cancel ride by passenger"""
    try:
        ride = RideRequest.objects.get(id=ride_id, passenger=request.user)
    except RideRequest.DoesNotExist:
        return Response(
            {'error': 'Ride not found'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    if ride.status in ['completed', 'cancelled_user', 'cancelled_driver']:
        return Response(
            {'error': 'Cannot cancel this ride'},
            status=status.HTTP_400_BAD_REQUEST
        )
    
    serializer = RideCancelSerializer(data=request.data)
    if serializer.is_valid():
        ride.status = 'cancelled_user'
        ride.cancelled_at = timezone.now()
        ride.cancellation_reason = serializer.validated_data.get('reason', '')
        ride.save()
        
        # Update driver status if ride was accepted
        if ride.driver and hasattr(ride.driver, 'driver_profile'):
            ride.driver.driver_profile.status = 'available'
            ride.driver.driver_profile.save()
        
        return Response({'message': 'Ride cancelled successfully'})
    
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
    
    serializer = RideRequestSerializer(rides, many=True)
    return Response({'rides': serializer.data})

@api_view(['GET'])
@permission_classes([IsAuthenticated])
def nearby_rides(request):
    """Get nearby pending ride requests for drivers"""
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
    
    if driver_profile.status != 'available':
        return Response({'rides': []})
    
    # Get driver's location from query params or profile
    driver_lat = request.query_params.get('latitude', driver_profile.current_latitude)
    driver_lon = request.query_params.get('longitude', driver_profile.current_longitude)
    
    if not driver_lat or not driver_lon:
        return Response(
            {'error': 'Driver location not available'},
            status=status.HTTP_400_BAD_REQUEST
        )
    
    # Get all pending rides
    pending_rides = RideRequest.objects.filter(status='pending')
    
    # Filter rides within broadcast radius and calculate distances
    nearby_rides_data = []
    for ride in pending_rides:
        distance = calculate_distance(
            driver_lat, driver_lon,
            ride.pickup_latitude, ride.pickup_longitude
        )
        
        if distance <= ride.broadcast_radius:
            ride_data = RideRequestSerializer(ride).data
            ride_data['distance_from_driver'] = round(distance)
            nearby_rides_data.append(ride_data)
    
    # Sort by distance
    nearby_rides_data.sort(key=lambda x: x['distance_from_driver'])
    
    return Response({'rides': nearby_rides_data})


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def accept_ride(request, ride_id):
    """Accept a ride request (first-come-first-served)"""
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
    
    try:
        ride = RideRequest.objects.get(id=ride_id, status='pending')
    except RideRequest.DoesNotExist:
        return Response(
            {'success': False, 'message': 'This ride has already been accepted by another driver'},
            status=status.HTTP_400_BAD_REQUEST
        )
    
    # Accept the ride
    ride.driver = request.user
    ride.status = 'accepted'
    ride.accepted_at = timezone.now()
    ride.save()
    
    # Update driver status to busy
    driver_profile.status = 'busy'
    driver_profile.save()
    
    serializer = RideRequestSerializer(ride)
    return Response({
        'success': True,
        'ride': serializer.data
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
        status__in=['accepted', 'in_progress']
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
def start_ride(request, ride_id):
    """Start a ride (when driver reaches passenger)"""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can start rides'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    try:
        ride = RideRequest.objects.get(id=ride_id, driver=request.user, status='accepted')
    except RideRequest.DoesNotExist:
        return Response(
            {'error': 'Ride not found or not in accepted status'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    ride.status = 'in_progress'
    ride.started_at = timezone.now()
    ride.save()
    
    return Response({'message': 'Ride started successfully'})


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def complete_ride(request, ride_id):
    """Complete a ride"""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can complete rides'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    try:
        ride = RideRequest.objects.get(id=ride_id, driver=request.user, status='in_progress')
    except RideRequest.DoesNotExist:
        return Response(
            {'error': 'Ride not found or not in progress'},
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
    
    return Response({'message': 'Ride completed successfully'})


@api_view(['POST'])
@permission_classes([IsAuthenticated])
def driver_cancel_ride(request, ride_id):
    """Cancel ride by driver"""
    if request.user.role != 'driver':
        return Response(
            {'error': 'Only drivers can cancel rides'},
            status=status.HTTP_403_FORBIDDEN
        )
    
    try:
        ride = RideRequest.objects.get(
            id=ride_id,
            driver=request.user,
            status__in=['accepted', 'in_progress']
        )
    except RideRequest.DoesNotExist:
        return Response(
            {'error': 'Ride not found'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    serializer = RideCancelSerializer(data=request.data)
    if serializer.is_valid():
        ride.status = 'cancelled_driver'
        ride.cancelled_at = timezone.now()
        ride.cancellation_reason = serializer.validated_data.get('reason', '')
        ride.driver = None  # Remove driver assignment
        ride.save()
        
        # Make driver available again
        request.user.driver_profile.status = 'available'
        request.user.driver_profile.save()
        
        return Response({'message': 'Ride cancelled successfully'})
    
    return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

@api_view(['GET'])
@permission_classes([IsAuthenticated])
def get_driver_location(request, ride_id):
    """Get driver's current location (for passenger)"""
    try:
        ride = RideRequest.objects.get(
            id=ride_id,
            passenger=request.user,
            status__in=['accepted', 'in_progress']
        )
    except RideRequest.DoesNotExist:
        return Response(
            {'error': 'Ride not found'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    if not ride.driver or not hasattr(ride.driver, 'driver_profile'):
        return Response(
            {'error': 'Driver not assigned'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    profile = ride.driver.driver_profile
    return Response({
        'latitude': profile.current_latitude,
        'longitude': profile.current_longitude,
        'last_updated': profile.last_location_update
    })


@api_view(['GET'])
@permission_classes([IsAuthenticated])
def get_passenger_location(request, ride_id):
    """Get passenger's location (for driver)"""
    try:
        ride = RideRequest.objects.get(
            id=ride_id,
            driver=request.user,
            status__in=['accepted', 'in_progress']
        )
    except RideRequest.DoesNotExist:
        return Response(
            {'error': 'Ride not found'},
            status=status.HTTP_404_NOT_FOUND
        )
    
    return Response({
        'latitude': ride.pickup_latitude,
        'longitude': ride.pickup_longitude,
        'pickup_address': ride.pickup_address
    })
