from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static

from .views import health_check

urlpatterns = [
    path('admin/', admin.site.urls),
    path("health/", health_check), # Health check endpoint
    
    # Authentication endpoints (at /api/auth/)
    path('api/auth/', include('accounts.urls')),  # accounts.urls have register, login, refresh endpoints
    
    # Driver APIs (driver profile, status, location, history)
    path('api/driver/', include('drivers.urls')),  # drivers.urls have all the driver-related endpoints
    
    # Rides endpoints (at /api/rides/)
    path('api/rides/', include('rides.urls')),      # rides.urls have all the actual ride-related endpoints
]

# Serve media files in development
if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)