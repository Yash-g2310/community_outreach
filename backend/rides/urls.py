from django.urls import path
from . import views

app_name = 'rides'

urlpatterns = [
    # Health check
    path('health/', views.health_check, name='health-check'),

    # views.py contains all the actual API endpoints implementations

    # User Profile
    path('user/profile/', views.user_profile, name='user-profile'),
    
    # Driver Profile & Status
    path('driver/profile/', views.driver_profile, name='driver-profile'),
    path('driver/status/', views.update_driver_status, name='driver-status'),
    path('driver/location/', views.update_driver_location, name='driver-location'),
    path('driver/nearby-rides/', views.nearby_rides, name='nearby-rides'),
    path('driver/current-ride/', views.driver_current_ride, name='driver-current-ride'),
    path('driver/history/', views.driver_ride_history, name='driver-ride-history'),
    
    # Passenger APIs
    path('passenger/nearby-drivers/', views.nearby_drivers_for_passenger, name='nearby-drivers'),
    path('passenger/request/', views.create_ride_request, name='create-ride'),
    path('passenger/current/', views.get_current_ride, name='current-ride'),
    path('passenger/history/', views.ride_history, name='ride-history'),
    path('passenger/<int:ride_id>/cancel/', views.cancel_ride, name='cancel-ride'),
    
    # Driver Ride Actions
    path('handle/<int:ride_id>/accept/', views.accept_ride, name='accept-ride'),
    path('handle/<int:ride_id>/reject/', views.reject_ride_offer, name='reject-ride'),
    path('handle/<int:ride_id>/complete/', views.complete_ride, name='complete-ride'),
    path('handle/<int:ride_id>/driver-cancel/', views.driver_cancel_ride, name='driver-cancel-ride'),
]
