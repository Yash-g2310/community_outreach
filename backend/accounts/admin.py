from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from accounts.models import User


@admin.register(User)
class UserAdmin(BaseUserAdmin):
    """Admin panel for custom User model"""

    list_display = [
        "username",
        "email",
        "role",
        "phone_number",
        "completed_rides",
        "is_active",
        "is_staff",
    ]

    list_filter = [
        "role",
        "is_active",
        "is_staff",
        "date_joined",
    ]

    search_fields = [
        "username",
        "email",
        "phone_number",
    ]

    ordering = ("username",)

    # Extend default Django UserAdmin fieldsets
    fieldsets = BaseUserAdmin.fieldsets + (
        (
            "Additional User Info",
            {
                "fields": (
                    "role",
                    "phone_number",
                    "profile_picture",
                    "completed_rides",
                )
            },
        ),
    )

    # For create user page in admin
    add_fieldsets = BaseUserAdmin.add_fieldsets + (
        (
            "Additional Info",
            {
                "fields": (
                    "role",
                    "phone_number",
                    "profile_picture",
                )
            },
        ),
    )
