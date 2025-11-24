from django.db import models
from django.contrib.auth.models import AbstractUser


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
    completed_rides = models.IntegerField(default=0)
    
    class Meta:
        db_table = 'users'
        
    def __str__(self):
        return f"{self.username} ({self.get_role_display()})"