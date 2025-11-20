from rest_framework import serializers
from .models import User, DriverProfile, RideRequest


class UserSerializer(serializers.ModelSerializer):
    """Serializer for User model"""
    profile_picture_url = serializers.SerializerMethodField(read_only=True)
    
    class Meta:
        model = User
        fields = ['id', 'username', 'email', 'role', 'phone_number', 
                  'completed_rides', 'profile_picture', 'profile_picture_url']
        read_only_fields = ['id', 'completed_rides', 'profile_picture_url']
        extra_kwargs = {
            'profile_picture': {'write_only': True, 'required': False}
        }
    
    def get_profile_picture_url(self, obj):
        """Return full URL for profile picture"""
        if obj.profile_picture:
            request = self.context.get('request')
            if request:
                return request.build_absolute_uri(obj.profile_picture.url)
            return obj.profile_picture.url
        return None


class DriverProfileSerializer(serializers.ModelSerializer):
    """Serializer for Driver Profile"""
    user = UserSerializer(read_only=True)
    
    class Meta:
        model = DriverProfile
        fields = ['id', 'user', 'vehicle_number', 'status', 
                  'current_latitude', 'current_longitude', 'last_location_update']
        read_only_fields = ['id', 'last_location_update']
    
    def to_representation(self, instance):
        """Ensure user serializer gets request context for URL generation"""
        representation = super().to_representation(instance)
        # Pass request context to nested UserSerializer
        if 'user' in representation and instance.user:
            request = self.context.get('request')
            user_serializer = UserSerializer(instance.user, context={'request': request})
            representation['user'] = user_serializer.data
        return representation


class DriverBasicSerializer(serializers.ModelSerializer):
    """Basic driver info for ride details"""
    username = serializers.CharField(source='user.username', read_only=True)
    phone_number = serializers.CharField(source='user.phone_number', read_only=True)
    
    class Meta:
        model = DriverProfile
        fields = ['id', 'username', 'phone_number', 'vehicle_number', 
                  'current_latitude', 'current_longitude']


class PassengerBasicSerializer(serializers.ModelSerializer):
    """Basic passenger info for ride details"""
    class Meta:
        model = User
        fields = ['id', 'username', 'phone_number']


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


class LocationUpdateSerializer(serializers.Serializer):
    """Serializer for location updates"""
    latitude = serializers.DecimalField(max_digits=9, decimal_places=6)
    longitude = serializers.DecimalField(max_digits=9, decimal_places=6)


class DriverStatusSerializer(serializers.Serializer):
    """Serializer for driver status updates"""
    status = serializers.ChoiceField(choices=['available', 'offline'])


class RideCancelSerializer(serializers.Serializer):
    """Serializer for ride cancellation"""
    reason = serializers.CharField(required=False, allow_blank=True)
