from django.urls import re_path
from . import consumers

websocket_urlpatterns = [
    # Driver receives new ride requests
    re_path(r'ws/driver/rides/$', consumers.RideNotificationConsumer.as_asgi()),
    
    # Passenger receives ride status updates
    re_path(r'ws/passenger/ride-status/$', consumers.PassengerRideStatusConsumer.as_asgi()),
    
    # Passenger receives nearby drivers updates
    re_path(r'ws/passenger/nearby-drivers/$', consumers.NearbyDriversConsumer.as_asgi()),
    
    # Real-time location tracking for active rides
    # URL format: ws/ride/{ride_id}/passenger/ or ws/ride/{ride_id}/driver/
    re_path(r'ws/ride/(?P<ride_id>\d+)/(?P<user_type>passenger|driver)/$', 
            consumers.RideTrackingConsumer.as_asgi()),
]
