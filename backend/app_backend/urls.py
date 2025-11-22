from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from rides.auth_views import (
    RegisterView,
    LoginView,
    RefreshTokenView,
    SessionBootstrapView,
)

urlpatterns = [
    path('admin/', admin.site.urls),
    
    # Authentication endpoints (at /api/auth/)
    path('api/auth/register/', RegisterView.as_view(), name='register'),
    path('api/auth/login/', LoginView.as_view(), name='login'),
    path('api/auth/refresh/', RefreshTokenView.as_view(), name='refresh-token'),
    path('api/auth/bootstrap-session/', SessionBootstrapView.as_view(), name='bootstrap-session'),
    
    # Rides endpoints (at /api/rides/)
    path('api/rides/', include('rides.urls')),      # rides.urls have all the actual ride-related endpoints
]

# Serve media files in development
if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
