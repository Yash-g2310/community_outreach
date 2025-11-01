from django.contrib import admin
from django.urls import path, include
from rides.auth_views import RegisterView, LoginView, RefreshTokenView

urlpatterns = [
    path('admin/', admin.site.urls),
    
    # Authentication endpoints (at /api/auth/)
    path('api/auth/register/', RegisterView.as_view(), name='register'),
    path('api/auth/login/', LoginView.as_view(), name='login'),
    path('api/auth/refresh/', RefreshTokenView.as_view(), name='refresh-token'),
    
    # Rides endpoints (at /api/rides/)
    path('api/rides/', include('rides.urls')),
]
