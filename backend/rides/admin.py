from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from .models import User, DriverProfile, RideRequest


@admin.register(User)
class UserAdmin(BaseUserAdmin):
    """Custom User admin"""
    list_display = ['username', 'email', 'role', 'phone_number', 'completed_rides', 'is_active']
    list_filter = ['role', 'is_staff', 'is_active']
    search_fields = ['username', 'email', 'phone_number']
    
    fieldsets = BaseUserAdmin.fieldsets + (
        ('Additional Info', {
            'fields': ('profile_picture', 'role', 'phone_number', 'completed_rides')
        }),
    )


@admin.register(DriverProfile)
class DriverProfileAdmin(admin.ModelAdmin):
    """Driver Profile admin"""
    list_display = ['user', 'vehicle_number', 'status', 'last_location_update']
    list_filter = ['status']
    search_fields = ['user__username', 'vehicle_number']
    readonly_fields = ['last_location_update']


@admin.register(RideRequest)
class RideRequestAdmin(admin.ModelAdmin):
    """Ride Request admin"""
    list_display = ['id', 'passenger', 'driver', 'status', 'requested_at', 'accepted_at', 'completed_at']
    list_filter = ['status', 'requested_at']
    search_fields = ['passenger__username', 'driver__username', 'pickup_address']
    readonly_fields = ['requested_at', 'accepted_at', 'completed_at', 'cancelled_at']
    date_hierarchy = 'requested_at'


