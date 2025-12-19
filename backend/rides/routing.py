"""
DEPRECATED: This module is kept for backward compatibility.
Use realtime.routing instead.

WebSocket routing has been moved to the realtime app.
"""

from realtime.routing import websocket_urlpatterns

__all__ = ["websocket_urlpatterns"]
