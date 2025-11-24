from django.contrib import admin
from drivers.models import DriverProfile


@admin.register(DriverProfile)
class DriverProfileAdmin(admin.ModelAdmin):
    """Admin panel for managing Driver Profiles"""

    list_display = [
        "user",
        "vehicle_number",
        "status",
        "current_latitude",
        "current_longitude",
        "last_location_update",
    ]

    list_filter = [
        "status",
        "last_location_update",
    ]

    search_fields = [
        "user__username",
        "vehicle_number",
    ]

    readonly_fields = [
        "last_location_update",
    ]

    ordering = ("user__username",)
