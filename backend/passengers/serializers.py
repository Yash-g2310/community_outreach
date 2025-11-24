from rest_framework import serializers
from django.contrib.auth import get_user_model

User = get_user_model()


class UserSerializer(serializers.ModelSerializer):
    """
    Serialize passenger/user profile details, including profile picture URL.
    Used for `/passengers/profile/`.
    """
    profile_picture_url = serializers.SerializerMethodField(read_only=True)

    class Meta:
        model = User
        fields = [
            'id', 'username', 'email', 'role', 'phone_number',
            'completed_rides', 'profile_picture', 'profile_picture_url'
        ]
        read_only_fields = ['id', 'completed_rides', 'profile_picture_url']
        extra_kwargs = {
            'profile_picture': {'write_only': True, 'required': False}
        }

    def get_profile_picture_url(self, obj):
        if obj.profile_picture:
            request = self.context.get('request')
            if request:
                return request.build_absolute_uri(obj.profile_picture.url)
            return obj.profile_picture.url
        return None


class PassengerBasicSerializer(serializers.ModelSerializer):
    """
    Basic passenger representation used inside ride responses.
    """
    class Meta:
        model = User
        fields = ['id', 'username', 'phone_number']


class RequestLocationSerializer(serializers.Serializer):
    """
    Validates latitude/longitude sent by passenger or driver.

    Expected body:
    {
        "latitude": <float>,
        "longitude": <float>
    }

    Notes:
    - Uses DecimalField for higher precision.
    - Restricts values to valid Earth coordinate ranges.
    - Can be reused for both Passenger and Driver location inputs.
    """

    latitude = serializers.DecimalField(
        max_digits=9,
        decimal_places=6,
        required=True,
        min_value=-90,
        max_value=90,
        help_text="Latitude between -90 and 90 degrees."
    )

    longitude = serializers.DecimalField(
        max_digits=9,
        decimal_places=6,
        required=True,
        min_value=-180,
        max_value=180,
        help_text="Longitude between -180 and 180 degrees."
    )
