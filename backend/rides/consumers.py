"""This module contains the logic for Server to receive/send websocket messages from/to clients."""

import logging
from typing import Dict, Any
from django.utils import timezone
from asgiref.sync import async_to_sync
from channels.db import database_sync_to_async
from django.contrib.auth import get_user_model
from .models import DriverProfile
from .utils import calculate_distance
from channels.generic.websocket import AsyncJsonWebsocketConsumer

User = get_user_model()


logger = logging.getLogger(__name__)

ACTIVE_PASSENGERS: Dict[int, Dict[str, Any]] = {}

@database_sync_to_async
def _get_driver_info(driver_id):
    user = User.objects.filter(id=driver_id).first()
    profile = DriverProfile.objects.filter(user_id=driver_id).first()
    return {
        "username": getattr(user, "username", None),
        "vehicle_number": getattr(profile, "vehicle_number", None),
    }

# Helper used by server-side code: This is used for sending only driver location/status updates to nearby passengers.
async def notify_nearby_passengers_async(
    channel_layer,
    driver_id: int,
    lat: float,
    lon: float,
    event_type: str = "driver_location_updated",
    radius_override: int = None,
    extra: Dict[str, Any] = None,
):
    """ Notify connected passengers whose subscription radius includes driver's location. 
    - channel_layer: get_channel_layer() or self.channel_layer 
    - event_type: one of "driver_location_updated" or "driver_status_changed" 
    - extra: additional keys (e.g., status, message) 
    """

    extra = extra or {}
    # 1. Fetch driver info only once
    try:
        driver_info = await _get_driver_info(driver_id)
    except Exception:
        driver_info = {"username": None, "vehicle_number": None}

    # 2. Build reusable base payload
    base_payload = {
        "type": event_type,
        "driver_id": driver_id,
        "latitude": lat,
        "longitude": lon,
        **driver_info,
        **extra,
    }

    # 3. Loop over active passengers
    for pid, info in list(ACTIVE_PASSENGERS.items()):
        try:
            p_lat = info.get("latitude")
            p_lon = info.get("longitude")
            radius = radius_override or info.get("radius", 1000)

            if p_lat is None or p_lon is None:
                continue

            # 4. Check distance only
            dist = calculate_distance(float(p_lat), float(p_lon), lat, lon)
            if dist > radius:
                continue

            # 5. Send update to this passenger only
            await channel_layer.send(info["channel_name"], base_payload)

        except Exception:
            logger.exception("Failed to notify passenger %s", pid)


# Synchronous wrapper (use from sync views)
def notify_nearby_passengers_sync(
    channel_layer,
    driver_id: int,
    lat: float,
    lon: float,
    event_type: str = "driver_location_updated",
    radius_override: int = None,
    extra: Dict[str, Any] = None,
):
    # Use async_to_sync to call the async notifier from sync context safely.
    try:
        async_to_sync(notify_nearby_passengers_async)(
            channel_layer, driver_id, lat, lon, event_type, radius_override, extra
        )
    except Exception:
        logger.exception("notify_nearby_passengers_sync failed for driver %s", driver_id)


class AppConsumer(AsyncJsonWebsocketConsumer):
    """
    Connect: Tells the server about a new WebSocket connection & joins clients to groups.
    Disconnect: Tells the server about closing WebSocket connection for a client.
    Receive: Handles incoming messages, sent by clients to server (passengers/drivers).
    Async Functions: Handles outgoing messages, sent by server to clients.
    """

    async def connect(self):
        self.user = self.scope["user"]

        if self.user.is_anonymous:
            await self.close()
            return

        # basic attributes
        self.user_id = getattr(self.user, "id", None)
        self.role = getattr(self.user, "role", None)  # 'driver' or 'user' assumed

        # personal group (useful for targeted server->user messages)
        self.user_group = f"user_{self.user_id}"
        await self.channel_layer.group_add(self.user_group, self.channel_name)

        # separate driver group (for driver-specific broadcasts)
        if self.role == "driver":
            self.driver_group = f"driver_{self.user_id}"
            await self.channel_layer.group_add(self.driver_group, self.channel_name)

        # ride groups the user has joined (set of ride_<id>)
        self.joined_rides = set()

        await self.accept()

        # send basic welcome
        await self.send_json({"type": "connection_established", "user_id": self.user_id, "role": self.role})

    async def disconnect(self, close_code):
        try:
            if hasattr(self, "user_group"):
                await self.channel_layer.group_discard(self.user_group, self.channel_name)
            if hasattr(self, "driver_group"):
                await self.channel_layer.group_discard(self.driver_group, self.channel_name)
            # remove passenger subscription
            if getattr(self, "role", None) == "user" and hasattr(self, "user_id"):
                ACTIVE_PASSENGERS.pop(self.user_id, None)
            if hasattr(self, "joined_rides"):
                for rg in list(self.joined_rides):
                    await self.channel_layer.group_discard(rg, self.channel_name)
        except Exception:
            logger.exception("Error during disconnect for user %s", self.user_id)

    # ----------------- (Incoming Messages) Messages sent by Client to Server-----------------
    async def receive_json(self, data):
        """This method triggers when server receives a JSON message from client over WebSocket.

        Using AsyncJsonWebsocketConsumer automatically parses incoming JSON into `data`.
        """
        msg_type = data.get("type")
        if not msg_type:
            return

        # PASSENGER: subscribe/unsubscribe to create entry in ACTIVE PASSENGERS for nearby drivers updates
        if msg_type == "subscribe_nearby" and self.role == "user":
            lat = data.get("latitude")
            lon = data.get("longitude")
            radius = data.get("radius", 1000)
            if lat is None or lon is None:
                await self.send_json({"type": "error", "message": "subscribe_nearby requires latitude and longitude"})
                return
            
            ACTIVE_PASSENGERS[self.user_id] = {
                "channel_name": self.channel_name,
                "latitude": float(lat),
                "longitude": float(lon),
                "radius": int(radius),
            }
            await self.send_json({"type": "subscribed_nearby", "radius": int(radius)})
            return

        # DRIVER: Driver runs Update Location when distance changes by 50m and sends location to server via this
        if msg_type == "driver_location_update" and self.role == "driver":
            lat = data.get("latitude")
            lon = data.get("longitude")
            if lat is None or lon is None:
                await self.send_json({"type": "error", "message": "driver_location_update requires lat/lon"})
                return

            # update DB profile (sync -> async wrapper)
            await self._update_driver_location_db(lat, lon)

            await notify_nearby_passengers_async(
                self.channel_layer,
                self.user_id,
                float(lat),
                float(lon),
                event_type="driver_location_updated",
            )
            return

        # TRACKING: For Joining/Leaving ride_<id> groups when Ride Request is accepted/completed
        if msg_type == "start_tracking":
            ride_id = data.get("ride_id")
            if ride_id is None:
                await self.send_json({"type": "error", "message": "start_tracking requires ride_id"})
                return
            
            ride_group = f"ride_{ride_id}"
            await self.channel_layer.group_add(ride_group, self.channel_name)
            self.joined_rides.add(ride_group)

            await self.send_json({"type": "tracking_started", "ride_id": ride_id})
            return

        if msg_type == "stop_tracking":
            ride_id = data.get("ride_id")
            if ride_id is None:
                return
            
            ride_group = f"ride_{ride_id}"
            await self.channel_layer.group_discard(ride_group, self.channel_name)
            self.joined_rides.discard(ride_group)

            await self.send_json({"type": "tracking_stopped", "ride_id": ride_id})
            return

        # TRACKING UPDATES: Drivers send location updates during an active ride to ride_<id> group
        if msg_type == "tracking_update" and self.role == "driver":
            ride_id = data.get("ride_id")
            lat = data.get("latitude")
            lon = data.get("longitude")

            if ride_id is None or lat is None or lon is None:
                return
            ride_group = f"ride_{ride_id}"

            # update DB profile (sync -> async wrapper)
            await self._update_driver_location_db(lat, lon)

            # broadcast to ride group; handler below will forward to clients
            message = {
                "type": "driver_track_location",
                "user_id": self.user_id,
                "latitude": float(lat),
                "longitude": float(lon),
            }
            await self.channel_layer.group_send(ride_group, message)
            return

    # ----------------- Handlers for group_send events (server to client)-----------------
    # These are invoked by channel_layer.group_send where "type" maps to method name

    async def ride_offer(self, event):
        await self.send_json(
            {
                "type": "ride_offer",
                "ride": event.get("ride_data"),
                "offer_id": event.get("offer_id"),
            }
        )

    async def ride_expired(self, event):
        await self.send_json(
            {
                "type": "ride_expired",
                "ride_id": event.get("ride_id"),
                "message": event.get("message", "Offer timed out"),
            }
        )

    async def ride_cancelled(self, event):
        await self.send_json(
            {
                "type": "ride_cancelled",
                "ride_id": event.get("ride_id"),
                "message": event.get("message", ""),
            }
        )

    async def ride_accepted(self, event):
        # notify passenger that driver accepted (server may send to user_<id> group)
        await self.send_json(
            {
                "type": "ride_accepted",
                "ride_id": event.get("ride_id"),
                "driver_id": event.get("driver_id"),
                "ride": event.get("ride_data", {}),
            }
        )

    async def ride_completed(self, event):
        # Sent by server to passenger and ride group when driver marks ride complete
        await self.send_json(
            {
                "type": "ride_completed",
                "ride_id": event.get("ride_id"),
                "message": event.get("message", "Ride completed"),
                "ride": event.get("ride_data", {}),
            }
        )

    async def no_drivers_available(self, event):
        # passengers receive this when no drivers are available within radius
        await self.send_json(
            {
                "type": "no_drivers_available",
                "ride_id": event.get("ride_id"),
                "message": event.get("message", "No drivers available"),
            }
        )

    async def driver_status_changed(self, event):
        # passengers receive this when driver toggles available/offline within radius
        await self.send_json(
            {
                "type": "driver_status_changed",
                "driver_id": event.get("driver_id"),
                "status": event.get("status"),
                "latitude": event.get("latitude"),
                "longitude": event.get("longitude"),
                # forward optional metadata if present (populated by notify_nearby_passengers_async)
                "username": event.get("username"),
                "vehicle_number": event.get("vehicle_number") or event.get("vehicle_no"),
                "message": event.get("message", ""),
            }
        )

    async def driver_location_updated(self, event):
        # forward optional metadata (username/vehicle_number) when available
        await self.send_json(
            {
                "type": "driver_location_updated",
                "driver_id": event.get("driver_id"),
                "latitude": event.get("latitude"),
                "longitude": event.get("longitude"),
                "username": event.get("username"),
                "vehicle_number": event.get("vehicle_number") or event.get("vehicle_no"),
            }
        )

    async def driver_track_location(self, event):
        # forwarded to clients who joined ride_<id> group
        await self.send_json(
            {
                "type": "driver_track_location",
                "user_id": event.get("user_id"),
                "latitude": event.get("latitude"),
                "longitude": event.get("longitude"),
            }
        )

    # ----------------- Small Helpers for Interacting with DB -----------------

    @database_sync_to_async
    def _update_driver_location_db(self, lat, lon):
        # update the driver's DriverProfile (safely)
        try:
            # self.user.driver_profile automatically loads the DriverProfile model through reverse relation
            # In DriverProfile, user-> OnetoOne Field & related_name='driver_profile'
            profile = self.user.driver_profile  
            profile.current_latitude = lat
            profile.current_longitude = lon

            profile.last_location_update = timezone.now()
            profile.save(update_fields=["current_latitude", "current_longitude", "last_location_update"])
            return True
        except Exception:
            logger.exception("Failed to update driver profile for %s", self.user_id)
            return False