from rest_framework import serializers
from django.contrib.auth import authenticate, get_user_model
from .models import User
from drivers.models import DriverProfile

class UserSerializer(serializers.ModelSerializer):
    profile_picture_url = serializers.SerializerMethodField(read_only=True)

    class Meta:
        model = User
        fields = [
            "id",
            "username",
            "email",
            "role",
            "phone_number",
            "completed_rides",
            "profile_picture",
            "profile_picture_url",
        ]
        read_only_fields = ["id", "completed_rides", "profile_picture_url"]
        extra_kwargs = {
            "profile_picture": {"write_only": True, "required": False}
        }

    def get_profile_picture_url(self, obj):
        """
        Generate absolute URL for Flutter.
        If Flutter receives only relative paths, images BREAK.
        """
        if obj.profile_picture:
            request = self.context.get("request")
            if request:
                return request.build_absolute_uri(obj.profile_picture.url)
            return obj.profile_picture.url
        return None

class LoginSerializer(serializers.Serializer):
    username = serializers.CharField()
    password = serializers.CharField(write_only=True)

    def validate(self, data):
        user = authenticate(username=data["username"], password=data["password"])
        if not user:
            raise serializers.ValidationError("Invalid username or password")
        return user


class RegisterSerializer(serializers.ModelSerializer):
    password = serializers.CharField(write_only=True)
    vehicle_number = serializers.CharField(required=False)

    class Meta:
        model = User
        fields = ['username', 'password', 'email', 'role', 'phone_number', "vehicle_number"]
    
    def validate_email(self, value):
        if User.objects.filter(email=value).exists():
            raise serializers.ValidationError("Email already exists")
        return value
    
    def validate(self, data):
        # If registering as driver, vehicle_number is required
        if data['role'] == 'driver' and not data.get('vehicle_number'):
            raise serializers.ValidationError({
                'vehicle_number': 'Vehicle number is required for drivers'
            })
        return data
    
    def create(self, validated_data):
        vehicle_number = validated_data.pop('vehicle_number', None)
        
        user = User.objects.create_user(
            username=validated_data['username'],
            email=validated_data['email'],
            password=validated_data['password'],
            role=validated_data['role'],
            phone_number=validated_data['phone_number']
        )
        
        # Create driver profile if role is driver
        if user.role == 'driver' and vehicle_number:
            DriverProfile.objects.create(
                user=user,
                vehicle_number=vehicle_number
            )
        
        return user
