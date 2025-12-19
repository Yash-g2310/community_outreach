from django.urls import path
from . import views

app_name = 'rides'

urlpatterns = [
    # Passenger APIs
    path('passenger/request/', views.create_ride_request, name='create-ride'),
    path('passenger/current/', views.get_current_ride, name='current-ride'),
    path('passenger/<int:ride_id>/cancel/', views.cancel_ride, name='cancel-ride'),
    
    # Driver Ride Actions
    path('handle/<int:ride_id>/accept/', views.accept_ride, name='accept-ride'),
    path('handle/<int:ride_id>/reject/', views.reject_ride_offer, name='reject-ride'),
    path('handle/<int:ride_id>/complete/', views.complete_ride, name='complete-ride'),
    path('handle/<int:ride_id>/driver-cancel/', views.driver_cancel_ride, name='driver-cancel-ride'),
]
