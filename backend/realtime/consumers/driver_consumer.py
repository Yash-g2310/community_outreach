"""Driver WebSocket consumer for real-time location updates and ride offers."""

import logging
from typing import Dict, Any

from channels.db import database_sync_to_async
from django.utils import timezone

from .base import BaseConsumer
from realtime.broadcast import broadcast_driver_location_async, broadcast_driver_status_async
from realtime.geo import get_async_driver_location_service

logger = logging.getLogger(__name__)


class DriverConsumer(BaseConsumer):
    """
    WebSocket consumer for drivers.
    
    Handles:
        - Driver location updates (broadcasts to nearby passengers)
        - Ride offer notifications
        - Status changes (available/busy/offline)
    """

    async def on_connect(self):
        """Set up driver-specific groups on connection."""
        if self.role != "driver":
            await self.send_error("This endpoint is for drivers only")
            await self.close()
            return

        # Join driver-specific group for targeted notifications
        self.driver_group = f"driver_{self.user_id}"
        await self._join_group(self.driver_group)

        await self.send_json({
            "type": "connection_established",
            "user_id": self.user_id,
            "role": self.role,
            "message": "Driver connected successfully",
        })

    async def on_disconnect(self, close_code):
        """Clean up on disconnect - remove from Redis GEO index."""
        try:
            service = get_async_driver_location_service()
            await service.remove_driver(self.user_id)
            logger.info("Driver %s disconnected and removed from GEO index", self.user_id)
        except Exception as e:
            logger.warning("Failed to remove driver %s from GEO: %s", self.user_id, e)

    async def handle_message(self, msg_type: str, data: Dict[str, Any]):
        """Handle driver-specific messages."""
        
        if msg_type == "driver_location_update":
            await self._handle_location_update(data)
        elif msg_type == "driver_status_update":
            await self._handle_status_update(data)
        else:
            await self.send_error(f"Unknown message type: {msg_type}")

    # ---------------------- Message Handlers ----------------------

    async def _handle_location_update(self, data: Dict[str, Any]):
        """
        Handle driver location update.
        Uses Redis GEO for fast geospatial indexing and geohash-based broadcasting.
        Only persists to DB periodically, not on every update.
        """
        lat = data.get("latitude")
        lon = data.get("longitude")

        if lat is None or lon is None:
            await self.send_error("driver_location_update requires latitude and longitude")
            return

        lat = float(lat)
        lon = float(lon)

        # Get driver info for broadcasting
        driver_info = await self._get_driver_info()
        
        # Update Redis GEO and broadcast to nearby passengers (geohash-based)
        result = await broadcast_driver_location_async(
            driver_id=self.user_id,
            lat=lat,
            lon=lon,
            username=driver_info.get("username"),
            vehicle_number=driver_info.get("vehicle_number"),
            status="available",
        )

        # Periodically persist to DB (every ~30 seconds or when moved significantly)
        # This reduces DB writes while keeping Redis as source of truth for real-time
        if result.get("geohash_changed") or result.get("moved"):
            await self._update_driver_location_db(lat, lon)
        
        logger.debug(
            "Driver %s location update: lat=%s, lon=%s, broadcasted=%s, notified=%s",
            self.user_id, lat, lon, 
            result.get("broadcasted"), result.get("passengers_notified", 0)
        )

    async def _handle_status_update(self, data: Dict[str, Any]):
        """Handle driver status change (available/busy/offline)."""
        status = data.get("status")
        
        if status not in ["available", "busy", "offline"]:
            await self.send_error("Invalid status. Must be: available, busy, or offline")
            return

        await self._update_driver_status_db(status)

        # Get driver info for broadcasting
        driver_info = await self._get_driver_info()
        location = await self._get_driver_location()

        # Broadcast status change using Redis GEO-based system
        if location.get("latitude") and location.get("longitude"):
            await broadcast_driver_status_async(
                driver_id=self.user_id,
                status=status,
                lat=location["latitude"],
                lon=location["longitude"],
                username=driver_info.get("username"),
                vehicle_number=driver_info.get("vehicle_number"),
            )

        # If going offline, remove from Redis GEO index
        if status == "offline":
            service = get_async_driver_location_service()
            await service.remove_driver(self.user_id)

        await self.send_success("status_updated", status=status)

    # ---------------------- Event Handlers (from group_send) ----------------------

    async def driver_status_changed(self, event):
        """Forward driver status change to client."""
        await self.send_json({
            "type": "driver_status_changed",
            "driver_id": event.get("driver_id"),
            "status": event.get("status"),
            "latitude": event.get("latitude"),
            "longitude": event.get("longitude"),
            "username": event.get("username"),
            "vehicle_number": event.get("vehicle_number") or event.get("vehicle_no"),
            "message": event.get("message", ""),
        })

    async def driver_location_updated(self, event):
        """Forward driver location update to client."""
        await self.send_json({
            "type": "driver_location_updated",
            "driver_id": event.get("driver_id"),
            "latitude": event.get("latitude"),
            "longitude": event.get("longitude"),
            "username": event.get("username"),
            "vehicle_number": event.get("vehicle_number") or event.get("vehicle_no"),
        })

    # ---------------------- Database Helpers ----------------------

    @database_sync_to_async
    def _get_driver_info(self) -> Dict[str, Any]:
        """Get driver's username and vehicle number."""
        try:
            profile = self.user.driver_profile
            return {
                "username": self.user.username,
                "vehicle_number": getattr(profile, "vehicle_number", None),
            }
        except Exception:
            return {"username": self.user.username if self.user else None, "vehicle_number": None}

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

    @database_sync_to_async
    def _update_driver_status_db(self, status: str) -> bool:
        """Update driver's status in database."""
        try:
            profile = self.user.driver_profile
            profile.status = status
            profile.save(update_fields=["status"])
            return True
        except Exception:
            logger.exception("Failed to update driver status for %s", self.user_id)
            return False

    @database_sync_to_async
    def _get_driver_location(self) -> Dict[str, Any]:
        """Get driver's current location from database."""
        try:
            profile = self.user.driver_profile
            return {
                "latitude": float(profile.current_latitude) if profile.current_latitude else None,
                "longitude": float(profile.current_longitude) if profile.current_longitude else None,
            }
        except Exception:
            return {"latitude": None, "longitude": None}