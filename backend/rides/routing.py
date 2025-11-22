from django.urls import re_path
from . import consumers

websocket_urlpatterns = [
    # URL:= ws://localhost:8000/ws/app/
    re_path(
        r"ws/app/$", 
        consumers.AppConsumer.as_asgi(),
        name="app-ws"
    ),
]
