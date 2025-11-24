"""Tells what to show in the Django admin interface for rides app"""

from django.contrib import admin
from .models import RideRequest, RideOffer

@admin.register(RideRequest)
class RideRequestAdmin(admin.ModelAdmin):
    """Ride Request admin"""
    list_display = ['id', 'passenger', 'driver', 'status', 'requested_at', 'accepted_at', 'completed_at']
    list_filter = ['status', 'requested_at']
    search_fields = ['passenger__username', 'driver__username', 'pickup_address']
    readonly_fields = ['requested_at', 'accepted_at', 'completed_at', 'cancelled_at']
    date_hierarchy = 'requested_at'


@admin.register(RideOffer)
class RideOfferAdmin(admin.ModelAdmin):
    list_display = ("ride", "driver", "order", "status", "sent_at", "responded_at")
    list_filter = ("status",)
    search_fields = ("ride__id", "driver__username")

