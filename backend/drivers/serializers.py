from rest_framework import serializers
from drivers.models import DriverProfile
from accounts.serializers import UserSerializer


class DriverProfileSerializer(serializers.ModelSerializer):
    """
    Full driver profile serializer
    """
    user = UserSerializer(read_only=True)

    class Meta:
        model = DriverProfile
        fields = [
            "id",
            "user",
            "vehicle_number",
            "status",
            "current_latitude",
            "current_longitude",
            "last_location_update",
        ]
        read_only_fields = ["id", "last_location_update"]

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
    """
    Lite version of driver info for ride details 
    (sent to passengers or used during ride request assignment).
    """
    username = serializers.CharField(source="user.username", read_only=True)
    phone_number = serializers.CharField(source="user.phone_number", read_only=True)

    class Meta:
        model = DriverProfile
        fields = [
            "id",
            "username",
            "phone_number",
            "vehicle_number",
            "current_latitude",
            "current_longitude",
        ]


class DriverStatusSerializer(serializers.Serializer):
    """
    Serializer for updating driver availability (available/offline).
    """
    status = serializers.ChoiceField(choices=["available", "offline"])


class LocationUpdateSerializer(serializers.Serializer):
    """
    Serializer for updating driver GPS location.
    """
    latitude = serializers.DecimalField(max_digits=9, decimal_places=6)
    longitude = serializers.DecimalField(max_digits=9, decimal_places=6)
