"""Base WebSocket consumer with shared functionality for all consumers."""

import logging
from typing import Dict, Any, Set

from channels.generic.websocket import AsyncJsonWebsocketConsumer
from channels.db import database_sync_to_async
from django.utils import timezone

logger = logging.getLogger(__name__)


class BaseConsumer(AsyncJsonWebsocketConsumer):
    """
    Base consumer with shared connection management and helper methods.
    
    Subclasses should override:
        - get_groups(): return list of groups to join on connect
        - handle_message(msg_type, data): handle incoming messages
    """

    async def connect(self):
        self.user = self.scope["user"]

        if self.user.is_anonymous:
            await self.close()
            return

        # Basic attributes available to all consumers
        self.user_id = getattr(self.user, "id", None)
        self.role = getattr(self.user, "role", None)
        
        # Track joined groups for cleanup
        self.joined_groups: Set[str] = set()
        
        # Personal group (useful for targeted server->user messages)
        self.user_group = f"user_{self.user_id}"
        await self._join_group(self.user_group)

        await self.accept()
        await self.on_connect()

    async def on_connect(self):
        """Override in subclass for custom connect logic."""
        await self.send_json({
            "type": "connection_established",
            "user_id": self.user_id,
            "role": self.role,
        })

    async def disconnect(self, close_code):
        """Leave all joined groups on disconnect."""
        try:
            for group in list(self.joined_groups):
                await self._leave_group(group)
            await self.on_disconnect(close_code)
        except Exception:
            logger.exception("Error during disconnect for user %s", getattr(self, 'user_id', 'unknown'))

    async def on_disconnect(self, close_code):
        """Override in subclass for custom disconnect logic."""
        pass

    async def receive_json(self, data: Dict[str, Any]):
        """Route incoming messages to appropriate handlers."""
        msg_type = data.get("type")
        if not msg_type:
            await self.send_error("Message type is required")
            return
        
        try:
            await self.handle_message(msg_type, data)
        except Exception as e:
            logger.exception("Error handling message type %s", msg_type)
            await self.send_error(f"Error processing {msg_type}")

    async def handle_message(self, msg_type: str, data: Dict[str, Any]):
        """Override in subclass to handle specific message types."""
        await self.send_error(f"Unknown message type: {msg_type}")

    # ---------------------- Group Management Helpers ----------------------

    async def _join_group(self, group_name: str):
        """Join a channel group and track it."""
        await self.channel_layer.group_add(group_name, self.channel_name)
        self.joined_groups.add(group_name)

    async def _leave_group(self, group_name: str):
        """Leave a channel group and untrack it."""
        await self.channel_layer.group_discard(group_name, self.channel_name)
        self.joined_groups.discard(group_name)

    # ---------------------- Response Helpers ----------------------

    async def send_error(self, message: str):
        """Send an error message to the client."""
        await self.send_json({
            "type": "error",
            "message": message,
        })

    async def send_success(self, event_type: str, **kwargs):
        """Send a success response to the client."""
        await self.send_json({
            "type": event_type,
            **kwargs,
        })

    # ---------------------- Common Event Handlers ----------------------
    # These handle group_send events from server-side code

    async def ride_offer(self, event):
        """Sent by server to a driver to offer a ride."""
        await self.send_json({
            "type": "new_ride_request",
            "ride": event.get("ride_data"),
            "offer_id": event.get("offer_id"),
        })

    async def ride_expired(self, event):
        """Sent when a ride offer expires."""
        await self.send_json({
            "type": "ride_expired",
            "ride_id": event.get("ride_id"),
            "message": event.get("message", "Offer timed out"),
        })

    async def ride_cancelled(self, event):
        """Sent when a ride is cancelled."""
        await self.send_json({
            "type": "ride_cancelled",
            "ride_id": event.get("ride_id"),
            "message": event.get("message", ""),
        })

    async def ride_accepted(self, event):
        """Sent when a ride is accepted."""
        await self.send_json({
            "type": "ride_accepted",
            "ride_id": event.get("ride_id"),
            "driver_id": event.get("driver_id"),
            "ride": event.get("ride_data", {}),
        })

    async def ride_completed(self, event):
        """Sent when a ride is completed."""
        await self.send_json({
            "type": "ride_completed",
            "ride_id": event.get("ride_id"),
            "message": event.get("message", "Ride completed"),
            "ride": event.get("ride_data", {}),
        })

    async def no_drivers_available(self, event):
        """Sent when no drivers are available."""
        await self.send_json({
            "type": "no_drivers_available",
            "ride_id": event.get("ride_id"),
            "message": event.get("message", "No drivers available"),
        })
