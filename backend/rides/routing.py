from django.urls import re_path
from . import consumers

websocket_urlpatterns = [
    # URL:= ws://localhost:8000/ws/driver/rides/
    re_path(
        r"ws/driver/rides/$",
        consumers.RideNotificationConsumer.as_asgi(),
        name="driver-rides-ws"
    ),
    # URL:= ws://localhost:8000/ws/ride/{ride_id}/passenger/ or driver/
    re_path(
        r"ws/ride/(?P<ride_id>\d+)/(?P<user_type>passenger|driver)/$",
        consumers.RideTrackingConsumer.as_asgi(),
        name="ride-tracking-ws"
    ),
    # URL:= ws://localhost:8000/ws/passenger/ride-status/
    re_path(
        r"ws/passenger/ride-status/$",
        consumers.PassengerRideStatusConsumer.as_asgi(),
        name="passenger-status-ws"
    ),
    # URL:= ws://localhost:8000/ws/passenger/nearby-drivers/
    re_path(
        r"ws/passenger/nearby-drivers/$",
        consumers.NearbyDriversConsumer.as_asgi(),
        name="passenger-nearby-ws"
    ),
    # URL:= ws://localhost:8000/ws/app/
    re_path(
        r"ws/app/$", 
        consumers.AppConsumer.as_asgi(),
        name="app-ws"
    ),
]
