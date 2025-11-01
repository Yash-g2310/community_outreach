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
    # Need to verify
    path('passenger/nearby-drivers/', views.nearby_drivers_for_passenger, name='nearby-drivers'),
    path('driver/nearby-rides/', views.nearby_rides, name='nearby-rides'),
    path('driver/current-ride/', views.driver_current_ride, name='driver-current-ride'),
    
    
    # Passenger Ride Management
    path('rides/request/', views.create_ride_request, name='create-ride'),
    path('rides/current/', views.get_current_ride, name='current-ride'),
    path('rides/history/', views.ride_history, name='ride-history'),
    path('rides/<int:ride_id>/cancel/', views.cancel_ride, name='cancel-ride'),
    
    # Driver Ride Actions
    path('rides/<int:ride_id>/accept/', views.accept_ride, name='accept-ride'),
    path('rides/<int:ride_id>/start/', views.start_ride, name='start-ride'),
    path('rides/<int:ride_id>/complete/', views.complete_ride, name='complete-ride'),
    path('rides/<int:ride_id>/driver-cancel/', views.driver_cancel_ride, name='driver-cancel-ride'),
    
    # Real-time Location Tracking
    path('rides/<int:ride_id>/driver-location/', views.get_driver_location, name='driver-location-track'),
    path('rides/<int:ride_id>/passenger-location/', views.get_passenger_location, name='passenger-location'),
]
