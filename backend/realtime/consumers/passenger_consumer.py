"""Passenger WebSocket consumer for nearby driver updates and ride notifications."""

import logging
from typing import Dict, Any

from .base import BaseConsumer
from realtime.geo import get_async_driver_location_service

logger = logging.getLogger(__name__)


class PassengerConsumer(BaseConsumer):
    """
    WebSocket consumer for passengers.
    
    Handles:
        - Subscribing to nearby driver updates (using Redis GEO)
        - Receiving ride status notifications
        - Driver location broadcasts via geohash channels
    
    Architecture:
        - Subscription info stored in Redis (not in-memory dict)
        - Passengers subscribe to geohash-partitioned channels
        - Receives updates only from drivers in their geohash tiles
    """

    async def on_connect(self):
        """Set up passenger-specific connection."""
        if self.role != "user":
            await self.send_error("This endpoint is for passengers only")
            await self.close()
            return

        await self.send_json({
            "type": "connection_established",
            "user_id": self.user_id,
            "role": self.role,
            "message": "Passenger connected successfully",
        })

    async def on_disconnect(self, close_code):
        """Clean up Redis subscription on disconnect."""
        try:
            service = get_async_driver_location_service()
            await service.unsubscribe_passenger(self.user_id)
            logger.info("Passenger %s disconnected and unsubscribed", self.user_id)
        except Exception as e:
            logger.warning("Failed to unsubscribe passenger %s: %s", self.user_id, e)

    async def handle_message(self, msg_type: str, data: Dict[str, Any]):
        """Handle passenger-specific messages."""
        
        if msg_type == "subscribe_nearby":
            await self._handle_subscribe_nearby(data)
        elif msg_type == "unsubscribe_nearby":
            await self._handle_unsubscribe_nearby()
        elif msg_type == "update_location":
            await self._handle_update_location(data)
        else:
            await self.send_error(f"Unknown message type: {msg_type}")

    # ---------------------- Message Handlers ----------------------

    async def _handle_subscribe_nearby(self, data: Dict[str, Any]):
        """
        Subscribe to nearby driver updates using Redis GEO.
        
        This stores the passenger's location in Redis and returns:
        - The geohashes they're subscribed to
        - Current nearby drivers (initial snapshot)
        """
        lat = data.get("latitude")
        lon = data.get("longitude")
        radius = data.get("radius", 1500)

        if lat is None or lon is None:
            await self.send_error("subscribe_nearby requires latitude and longitude")
            return

        lat = float(lat)
        lon = float(lon)
        radius = int(radius)

        try:
            service = get_async_driver_location_service()
            result = await service.subscribe_passenger_to_area(
                passenger_id=self.user_id,
                channel_name=self.channel_name,
                lat=lat,
                lon=lon,
                radius_meters=radius,
            )

            # Send initial nearby drivers snapshot
            nearby_drivers = result.get("nearby_drivers", [])
            
            await self.send_json({
                "type": "subscribed_nearby",
                "status": "success",
                "radius": radius,
                "geohashes": result.get("geohashes", []),
                "nearby_drivers_count": len(nearby_drivers),
            })

            # Send each nearby driver as a location update
            for driver in nearby_drivers:
                await self.send_json({
                    "type": "driver_location_updated",
                    "driver_id": driver.get("driver_id"),
                    "latitude": driver.get("latitude"),
                    "longitude": driver.get("longitude"),
                    "username": driver.get("username"),
                    "vehicle_number": driver.get("vehicle_number"),
                    "distance_meters": driver.get("distance_meters"),
                })

            logger.info(
                "Passenger %s subscribed to %d geohashes, found %d nearby drivers",
                self.user_id, len(result.get("geohashes", [])), len(nearby_drivers)
            )

        except Exception as e:
            logger.exception("Failed to subscribe passenger %s: %s", self.user_id, e)
            await self.send_error(f"Failed to subscribe: {str(e)}")

    async def _handle_unsubscribe_nearby(self):
        """Unsubscribe from nearby driver updates."""
        try:
            service = get_async_driver_location_service()
            await service.unsubscribe_passenger(self.user_id)
            await self.send_success("unsubscribed_nearby")
        except Exception as e:
            await self.send_error(f"Failed to unsubscribe: {str(e)}")

    async def _handle_update_location(self, data: Dict[str, Any]):
        """
        Update passenger location and re-subscribe to new geohash tiles.
        
        This handles the case when passenger moves to a new area.
        """
        lat = data.get("latitude")
        lon = data.get("longitude")
        radius = data.get("radius")
        
        if lat is None or lon is None:
            await self.send_error("update_location requires latitude and longitude")
            return

        lat = float(lat)
        lon = float(lon)

        try:
            service = get_async_driver_location_service()
            
            # Get current subscription to check if still exists
            current_sub = await service.get_passenger_subscription(self.user_id)
            if not current_sub:
                await self.send_error("Not subscribed. Call subscribe_nearby first.")
                return
            
            # Re-subscribe with new location (updates geohashes if needed)
            radius = int(radius) if radius else int(current_sub.get("radius", 1500))
            
            result = await service.subscribe_passenger_to_area(
                passenger_id=self.user_id,
                channel_name=self.channel_name,
                lat=lat,
                lon=lon,
                radius_meters=radius,
            )

            await self.send_json({
                "type": "location_updated",
                "status": "success",
                "geohashes": result.get("geohashes", []),
                "nearby_drivers_count": len(result.get("nearby_drivers", [])),
            })

            # Optionally send updated nearby drivers
            for driver in result.get("nearby_drivers", []):
                await self.send_json({
                    "type": "driver_location_updated",
                    "driver_id": driver.get("driver_id"),
                    "latitude": driver.get("latitude"),
                    "longitude": driver.get("longitude"),
                    "username": driver.get("username"),
                    "vehicle_number": driver.get("vehicle_number"),
                    "distance_meters": driver.get("distance_meters"),
                })

        except Exception as e:
            logger.exception("Failed to update location for passenger %s: %s", self.user_id, e)
            await self.send_error(f"Failed to update location: {str(e)}")

    # ---------------------- Event Handlers (from channel.send) ----------------------

    async def driver_status_changed(self, event):
        """Receive driver status change notification from broadcast."""
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
        """Receive driver location update notification from broadcast."""
        await self.send_json({
            "type": "driver_location_updated",
            "driver_id": event.get("driver_id"),
            "latitude": event.get("latitude"),
            "longitude": event.get("longitude"),
            "username": event.get("username"),
            "vehicle_number": event.get("vehicle_number") or event.get("vehicle_no"),
            "geohash": event.get("geohash"),
        })
