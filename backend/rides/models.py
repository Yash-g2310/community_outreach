from django.db import models
from django.contrib.auth.models import AbstractUser
from django.utils import timezone


class User(AbstractUser):
    """Extended user model with role selection"""
    ROLE_CHOICES = [
        ('user', 'Passenger'),
        ('driver', 'E-Rickshaw Owner'),
    ]
    
    # Role & basic info
    role = models.CharField(max_length=10, choices=ROLE_CHOICES)
    phone_number = models.CharField(max_length=15)
    profile_picture = models.ImageField(upload_to='profile_pictures/', null=True, blank=True)
    
    # Ride statistics (common for both user and driver)
    completed_rides = models.IntegerField(default=0)
    
    class Meta:
        db_table = 'users'
        
    def __str__(self):
        return f"{self.username} ({self.get_role_display()})"


class DriverProfile(models.Model):
    """Driver-specific details and availability status"""
    STATUS_CHOICES = [
        ('available', 'Available'),
        ('busy', 'Busy'),
        ('offline', 'Offline'),
    ]
    
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name='driver_profile')
    
    # Vehicle details
    vehicle_number = models.CharField(max_length=20, unique=True)
    # vehicle_model = models.CharField(max_length=100, blank=True)  # Commented out for simplicity
    # license_number = models.CharField(max_length=50, blank=True)  # Commented out - trusting drivers
    
    # Status & location (for real-time tracking with OpenStreetMap)
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='offline')
    current_latitude = models.DecimalField(max_digits=10, decimal_places=6, null=True, blank=True)
    current_longitude = models.DecimalField(max_digits=10, decimal_places=6, null=True, blank=True)
    last_location_update = models.DateTimeField(null=True, blank=True)
    
    class Meta:
        db_table = 'driver_profiles'
        
    def __str__(self):
        return f"{self.user.username} - {self.vehicle_number}"


class RideRequest(models.Model):
    """Simplified ride request model for WebSocket-based notifications"""
    STATUS_CHOICES = [
        ('pending', 'Pending'),
        ('accepted', 'Accepted'),
        ('no_drivers', 'No Drivers Available'),
        ('in_progress', 'In Progress'),
        ('completed', 'Completed'),
        ('cancelled_user', 'Cancelled by User'),
        ('cancelled_driver', 'Cancelled by Driver'),
    ]
    
    # Foreign keys
    passenger = models.ForeignKey(User, on_delete=models.CASCADE, related_name='ride_requests')
    driver = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True, related_name='accepted_rides')
    
    # Pickup location
    pickup_latitude = models.DecimalField(max_digits=10, decimal_places=6)
    pickup_longitude = models.DecimalField(max_digits=10, decimal_places=6)
    pickup_address = models.TextField(null=True, blank=True)
    
    # Dropoff location (only address needed)
    dropoff_address = models.TextField(null=True, blank=True)
    
    # Passenger count
    number_of_passengers = models.IntegerField(default=1)
    
    # Status & timing
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='pending')
    
    # Broadcast radius in meters (0.5 km = 500 meters)
    broadcast_radius = models.IntegerField(default=500)
    
    # Timestamps
    requested_at = models.DateTimeField(auto_now_add=True)
    accepted_at = models.DateTimeField(null=True, blank=True)
    started_at = models.DateTimeField(null=True, blank=True)
    completed_at = models.DateTimeField(null=True, blank=True)
    cancelled_at = models.DateTimeField(null=True, blank=True)
    
    # Cancellation reason
    cancellation_reason = models.TextField(null=True, blank=True)
    
    class Meta:
        db_table = 'ride_requests'
        ordering = ['-requested_at']
        
    def __str__(self):
        return f"Ride #{self.id} - {self.passenger.username} - {self.status}"
