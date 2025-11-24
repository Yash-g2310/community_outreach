from rest_framework import serializers
from django.contrib.auth import get_user_model
from .models import RideRequest

from passengers.serializers import PassengerBasicSerializer
from drivers.serializers import DriverBasicSerializer

User = get_user_model()


class RideRequestSerializer(serializers.ModelSerializer):
    """Serializer for Ride Requests"""
    passenger = PassengerBasicSerializer(read_only=True)
    driver = DriverBasicSerializer(read_only=True, source='driver.driver_profile')
    
    class Meta:
        model = RideRequest
        fields = ['id', 'passenger', 'driver', 'pickup_latitude', 'pickup_longitude',
                  'pickup_address', 'dropoff_address', 'number_of_passengers', 
                  'status', 'broadcast_radius', 'requested_at', 'accepted_at', 
                  'completed_at', 'cancelled_at', 'cancellation_reason']
        read_only_fields = ['id', 'passenger', 'driver', 'status', 'requested_at',
                           'accepted_at', 'completed_at', 'cancelled_at']


class RideRequestCreateSerializer(serializers.ModelSerializer):
    """Serializer for creating ride requests"""
    # Make broadcast_radius optional with default 1000m
    broadcast_radius = serializers.IntegerField(default=1000, required=False)
    
    class Meta:
        model = RideRequest
        fields = ['pickup_latitude', 'pickup_longitude', 'pickup_address',
                  'dropoff_address', 'number_of_passengers', 'broadcast_radius']


class RideCancelSerializer(serializers.Serializer):
    """Serializer for ride cancellation"""
    reason = serializers.CharField(required=False, allow_blank=True)
