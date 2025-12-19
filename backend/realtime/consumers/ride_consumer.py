"""Ride tracking WebSocket consumer for real-time ride updates."""

import logging
from typing import Dict, Any, Set

from channels.db import database_sync_to_async
from django.utils import timezone

from .base import BaseConsumer

logger = logging.getLogger(__name__)


class RideConsumer(BaseConsumer):
    """
    WebSocket consumer for ride tracking.
    
    Used by both drivers and passengers to:
        - Track active ride location in real-time
        - Receive ride status updates (accepted, completed, cancelled)
        - Send/receive live location during active rides
    
    This is a unified consumer that both roles can use for ride-specific communication.
    """

    async def on_connect(self):
        """Set up ride tracking connection."""
        # Track which ride groups this connection has joined
        self.joined_rides: Set[str] = set()

        # If driver, also join their driver group for ride offers
        if self.role == "driver":
            self.driver_group = f"driver_{self.user_id}"
            await self._join_group(self.driver_group)

        await self.send_json({
            "type": "connection_established",
            "user_id": self.user_id,
            "role": self.role,
            "message": "Ride tracking connection established",
        })

    async def handle_message(self, msg_type: str, data: Dict[str, Any]):
        """Handle ride tracking messages."""
        
        if msg_type == "start_tracking":
            await self._handle_start_tracking(data)
        elif msg_type == "stop_tracking":
            await self._handle_stop_tracking(data)
        elif msg_type == "tracking_update":
            await self._handle_tracking_update(data)
        else:
            await self.send_error(f"Unknown message type: {msg_type}")

    # ---------------------- Message Handlers ----------------------

    async def _handle_start_tracking(self, data: Dict[str, Any]):
        """
        Join a ride tracking group.
        Both driver and passenger join ride_<ride_id> to share location updates.
        """
        ride_id = data.get("ride_id")
        
        if ride_id is None:
            await self.send_error("start_tracking requires ride_id")
            return

        # Validate ride exists and user is part of it
        is_valid = await self._validate_ride_participant(ride_id)
        if not is_valid:
            await self.send_error("You are not authorized to track this ride")
            return

        ride_group = f"ride_{ride_id}"
        await self._join_group(ride_group)
        self.joined_rides.add(ride_group)

        await self.send_success("tracking_started", ride_id=ride_id)

    async def _handle_stop_tracking(self, data: Dict[str, Any]):
        """Leave a ride tracking group."""
        ride_id = data.get("ride_id")
        
        if ride_id is None:
            return

        ride_group = f"ride_{ride_id}"
        await self._leave_group(ride_group)
        self.joined_rides.discard(ride_group)

        await self.send_success("tracking_stopped", ride_id=ride_id)

    async def _handle_tracking_update(self, data: Dict[str, Any]):
        """
        Driver sends location update during an active ride.
        Broadcasts to everyone in the ride group.
        """
        if self.role != "driver":
            await self.send_error("Only drivers can send tracking updates")
            return

        ride_id = data.get("ride_id")
        lat = data.get("latitude")
        lon = data.get("longitude")

        if ride_id is None or lat is None or lon is None:
            await self.send_error("tracking_update requires ride_id, latitude, and longitude")
            return

        ride_group = f"ride_{ride_id}"

        # Update driver location in DB
        await self._update_driver_location_db(float(lat), float(lon))

        # Broadcast to ride group
        await self.channel_layer.group_send(ride_group, {
            "type": "driver_track_location",
            "user_id": self.user_id,
            "latitude": float(lat),
            "longitude": float(lon),
        })

    # ---------------------- Event Handlers (from group_send) ----------------------

    async def driver_track_location(self, event):
        """Forward driver location during ride tracking."""
        await self.send_json({
            "type": "driver_track_location",
            "user_id": event.get("user_id"),
            "latitude": event.get("latitude"),
            "longitude": event.get("longitude"),
        })

    # ---------------------- Database Helpers ----------------------

    @database_sync_to_async
    def _validate_ride_participant(self, ride_id: int) -> bool:
        """Check if user is authorized to track this ride."""
        from rides.models import RideRequest
        try:
            ride = RideRequest.objects.get(id=ride_id)
            # User must be either the passenger or the driver
            return ride.passenger_id == self.user_id or ride.driver_id == self.user_id
        except RideRequest.DoesNotExist:
            return False

    @database_sync_to_async
    def _update_driver_location_db(self, lat: float, lon: float) -> bool:
        """Update driver's location in database."""
        try:
            profile = self.user.driver_profile
            profile.current_latitude = lat
            profile.current_longitude = lon
            profile.last_location_update = timezone.now()
            profile.save(update_fields=["current_latitude", "current_longitude", "last_location_update"])
            return True
        except Exception:
            logger.exception("Failed to update driver profile for %s", self.user_id)
            return False