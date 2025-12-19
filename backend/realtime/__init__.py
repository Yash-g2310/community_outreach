"""
Realtime app for WebSocket communication with Redis GEO-based driver tracking.

This app provides:
- WebSocket consumers for drivers, passengers, and ride tracking
- Redis GEO-based driver location indexing and geohash broadcasting
- Notification helpers for sending real-time updates
- Utility functions for distance calculations
- JWT/Cookie authentication middleware for WebSocket connections

Key Components:
    - geo.py: Redis GEO service for driver locations & geohash management
    - broadcast.py: Geohash-partitioned location broadcasting
    - consumers/: WebSocket consumers (driver, passenger, ride)
    - notifications.py: Ride event notification helpers

Usage:
    from realtime.consumers import DriverConsumer, PassengerConsumer, RideConsumer
    from realtime.notifications import notify_driver_event, notify_passenger_event
    from realtime.broadcast import broadcast_driver_location, broadcast_driver_status
    from realtime.geo import get_driver_location_service
    from realtime.utils import calculate_distance
"""

default_app_config = 'realtime.apps.RealtimeConfig'