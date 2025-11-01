from rest_framework import serializers
from django.contrib.auth import authenticate
from .models import User, DriverProfile


class LoginSerializer(serializers.Serializer):
    """Serializer for login (username/password)"""
    username = serializers.CharField()
    password = serializers.CharField(write_only=True)


class RegisterSerializer(serializers.Serializer):
    """Serializer for user registration"""
    username = serializers.CharField()
    email = serializers.EmailField()
    password = serializers.CharField(write_only=True)
    role = serializers.ChoiceField(choices=['user', 'driver'])
    phone_number = serializers.CharField(required=False, allow_blank=True)
    vehicle_number = serializers.CharField(required=False, allow_blank=True)
    
    def validate_username(self, value):
        if User.objects.filter(username=value).exists():
            raise serializers.ValidationError("Username already exists")
        return value
    
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
            phone_number=validated_data.get('phone_number', '')
        )
        
        # Create driver profile if role is driver
        if user.role == 'driver' and vehicle_number:
            DriverProfile.objects.create(
                user=user,
                vehicle_number=vehicle_number
            )
        
        return user
