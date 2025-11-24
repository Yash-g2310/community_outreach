from django.db import models
from django.utils import timezone
from django.conf import settings

User = settings.AUTH_USER_MODEL

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
    last_location_update = models.DateTimeField(default=timezone.now)
    
    class Meta:
        db_table = 'driver_profiles'
        
    def __str__(self):
        return f"{self.user.username} - {self.vehicle_number}"
