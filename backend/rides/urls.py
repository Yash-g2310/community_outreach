from django.urls import path
from . import views

app_name = 'rides'

urlpatterns = [
    # User Profile
    path('user/profile/', views.user_profile, name='user-profile'),
    
    # Driver Profile & Status
    path('driver/profile/', views.driver_profile, name='driver-profile'),
    path('driver/status/', views.update_driver_status, name='driver-status'),
    path('driver/location/', views.update_driver_location, name='driver-location'),
    path('passenger/nearby-drivers/', views.nearby_drivers_for_passenger, name='nearby-drivers'),
    path('driver/nearby-rides/', views.nearby_rides, name='nearby-rides'),
    path('driver/current-ride/', views.driver_current_ride, name='driver-current-ride'),
    
    path('passenger/request/', views.create_ride_request, name='create-ride'),
    path('passenger/current/', views.get_current_ride, name='current-ride'),
    # Need to verify
    path('passenger/history/', views.ride_history, name='ride-history'),
    path('passenger/<int:ride_id>/cancel/', views.cancel_ride, name='cancel-ride'),
    
    # Driver Ride Actions
    path('handle/<int:ride_id>/accept/', views.accept_ride, name='accept-ride'),
    path('handle/<int:ride_id>/complete/', views.complete_ride, name='complete-ride'),
    path('handle/<int:ride_id>/driver-cancel/', views.driver_cancel_ride, name='driver-cancel-ride'),
    
    # Real-time Location Tracking
    path('handle/<int:ride_id>/driver-location/', views.get_driver_location, name='driver-location-track'),
    path('handle/<int:ride_id>/passenger-location/', views.get_passenger_location, name='passenger-location'),
]
