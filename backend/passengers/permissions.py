# passengers/permissions.py
from rest_framework.permissions import BasePermission

class IsPassenger(BasePermission):
    """
    Allows access only to users with role == 'user' (passenger).
    Keeps role check logic centralized.
    """
    def has_permission(self, request, view):
        user = getattr(request, "user", None)
        if not user or not user.is_authenticated:
            return False
        return getattr(user, "role", None) == "user"
