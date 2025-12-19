"""WebSocket URL routing for the realtime app."""

from django.urls import re_path

from .consumers.driver_consumer import DriverConsumer
from .consumers.passenger_consumer import PassengerConsumer
from .consumers.ride_consumer import RideConsumer

websocket_urlpatterns = [
    # Driver-specific WebSocket endpoint
    # URL: ws://localhost:8000/ws/driver/
    re_path(
        r"ws/driver/$",
        DriverConsumer.as_asgi(),
        name="driver-ws"
    ),
    
    # Passenger-specific WebSocket endpoint
    # URL: ws://localhost:8000/ws/passenger/
    re_path(
        r"ws/passenger/$",
        PassengerConsumer.as_asgi(),
        name="passenger-ws"
    ),
    
    # Ride tracking WebSocket endpoint (shared by both roles)
    # URL: ws://localhost:8000/ws/ride/
    re_path(
        r"ws/ride/$",
        RideConsumer.as_asgi(),
        name="ride-ws"
    ),
]