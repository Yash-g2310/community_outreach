"""Contains WebSocket handlers that deliver messages to clients"""

import json
import logging
from typing import Dict, Any
from asgiref.sync import async_to_sync
from channels.generic.websocket import AsyncWebsocketConsumer
from channels.db import database_sync_to_async
from django.contrib.auth import get_user_model
from drivers.models import DriverProfile
from .utils import calculate_distance

User = get_user_model()


logger = logging.getLogger(__name__)

ACTIVE_PASSENGERS: Dict[int, Dict[str, Any]] = {}

# Helper used by server-side code: call this to notify nearby passengers (async)
async def notify_nearby_passengers_async(
    channel_layer,
    driver_id: int,
    lat: float,
    lon: float,
    event_type: str = "driver_location_updated",
    radius_override: int = None,
    extra: Dict[str, Any] = None,
):
    """
    Notify connected passengers whose subscription radius includes driver's location.
    - channel_layer: get_channel_layer() or self.channel_layer
    - event_type: one of "driver_location_updated" or "driver_status_changed"
    - extra: additional keys (e.g., status, message)
    """
    extra = extra or {}
    for pid, info in list(ACTIVE_PASSENGERS.items()):
        try:
            p_lat = info.get("latitude")
            p_lon = info.get("longitude")
            p_radius = info.get("radius", 1000) if radius_override is None else radius_override
            if p_lat is None or p_lon is None:
                continue
            dist = calculate_distance(float(p_lat), float(p_lon), float(lat), float(lon))
            if dist <= float(p_radius):
                    # Enrich payload with basic driver info (username, vehicle_number)
                    # Enrich driver payload with basic info from DB.
                    driver_info: Dict[str, Any] = {"username": None, "vehicle_number": None}
                    try:
                        def _sync_fetch_driver_info(did: int) -> Dict[str, Any]:
                            try:
                                user = User.objects.filter(id=did).first()
                                profile = DriverProfile.objects.filter(user_id=did).first()
                                return {
                                    "username": getattr(user, "username", None) if user is not None else None,
                                    "vehicle_number": getattr(profile, "vehicle_number", None) if profile is not None else None,
                                }
                            except Exception:
                                return {"username": None, "vehicle_number": None}

                        driver_info = await database_sync_to_async(_sync_fetch_driver_info)(driver_id)
                    except Exception:
                        driver_info = {"username": None, "vehicle_number": None}

                    # Send direct to passenger's channel name
                    payload = {
                        "type": event_type,  # MUST match a method name on consumer
                        "driver_id": driver_id,
                        "latitude": lat,
                        "longitude": lon,
                        **(driver_info or {}),
                    }
                    if extra:
                        payload.update(extra)
                    await channel_layer.send(info["channel_name"], payload)
                    print(
                        f"Sending driver update → passenger={pid}, driver={driver_id}, "
                        f"lat={lat}, lon={lon}, event={event_type}"
                    )
        except Exception:
            logger.exception("notify_nearby_passengers_async error for passenger %s", pid)


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


# --- Unified AppConsumer ---
class AppConsumer(AsyncWebsocketConsumer):
    """
    Unified websocket consumer for drivers & passengers.
    Connect clients to a single endpoint:
        ws://.../ws/app/?token=<JWT>
    Messages use a 'type' field for routing.
    """

    async def connect(self):
        self.user = self.scope["user"]

        if self.user.is_anonymous:
            await self.close()
            return

        # basic attributes
        self.current_ride_id = None  # kept for future use if you want
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
        await self.send_json(
            {"type": "connection_established", "user_id": self.user_id, "role": self.role}
        )

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

    # ----------------- incoming messages from client to server-----------------
    async def receive(self, text_data=None, bytes_data=None):
        # expect JSON text
        try:
            data = json.loads(text_data)
        except Exception:
            logger.debug("Non-JSON or empty message from user %s", self.user_id)
            return

        msg_type = data.get("type")
        if not msg_type:
            return

        # ping / pong
        if msg_type == "ping":
            await self.send_json({"type": "pong"})
            return

        # PASSENGER: subscribe/unsubscribe nearby updates (radius-based)
        if msg_type == "subscribe_nearby" and self.role == "user":
            lat = data.get("latitude")
            lon = data.get("longitude")
            radius = data.get("radius", 1000)
            if lat is None or lon is None:
                await self.send_json(
                    {
                        "type": "error",
                        "message": "subscribe_nearby requires latitude and longitude",
                    }
                )
                return
            ACTIVE_PASSENGERS[self.user_id] = {
                "channel_name": self.channel_name,
                "latitude": float(lat),
                "longitude": float(lon),
                "radius": int(radius),
            }
            await self.send_json({"type": "subscribed_nearby", "radius": int(radius)})
            return

        if msg_type == "unsubscribe_nearby" and self.role == "user":
            ACTIVE_PASSENGERS.pop(self.user_id, None)
            await self.send_json({"type": "unsubscribed_nearby"})
            return

        # DRIVER: location/status updates (driver app sends these)
        if msg_type == "driver_location_update" and self.role == "driver":
            lat = data.get("latitude")
            lon = data.get("longitude")
            if lat is None or lon is None:
                await self.send_json(
                    {
                        "type": "error",
                        "message": "driver_location_update requires lat/lon",
                    }
                )
                return

            # update DB profile (sync -> async wrapper)
            await self._update_driver_location_db(lat, lon)

            # FIX: driver_location_update is for "searching" phase only;
            # ride tracking is handled by separate "tracking_update" below.
            await notify_nearby_passengers_async(
                self.channel_layer,
                self.user_id,
                float(lat),
                float(lon),
                event_type="driver_location_updated",
            )
            return

        if msg_type == "driver_status_update" and self.role == "driver":
            status = data.get("status")  # 'available' or 'offline' etc.
            message = data.get("message", "")

            # optional validation
            if status not in {"available", "offline", "busy"}:
                await self.send_json(
                    {
                        "type": "error",
                        "message": "Invalid driver status",
                    }
                )
                return

            # update DB
            await self._update_driver_status_db(status)

            # notify nearby passengers (if we know driver's location)
            profile = await self._get_driver_location()
            if profile:
                lat = profile.get("latitude")
                lon = profile.get("longitude")
                if lat is not None and lon is not None:
                    await notify_nearby_passengers_async(
                        self.channel_layer,
                        self.user_id,
                        float(lat),
                        float(lon),
                        event_type="driver_status_changed",
                        extra={"status": status, "message": message},
                    )
            return

        # TRACKING: join/leave/emit tracking updates
        if msg_type == "start_tracking":
            ride_id = data.get("ride_id")
            if ride_id is None:
                await self.send_json(
                    {"type": "error", "message": "start_tracking requires ride_id"}
                )
                return
            ride_group = f"ride_{ride_id}"
            await self.channel_layer.group_add(ride_group, self.channel_name)
            self.joined_rides.add(ride_group)
            # optional: remember current ride for this connection
            self.current_ride_id = ride_id
            await self.send_json({"type": "tracking_started", "ride_id": ride_id})
            return

        if msg_type == "stop_tracking":
            ride_id = data.get("ride_id")
            if ride_id is None:
                return
            ride_group = f"ride_{ride_id}"
            await self.channel_layer.group_discard(ride_group, self.channel_name)
            self.joined_rides.discard(ride_group)
            # reset current ride if it matches
            if self.current_ride_id == ride_id:
                self.current_ride_id = None
            await self.send_json({"type": "tracking_stopped", "ride_id": ride_id})
            return

        if msg_type == "tracking_update":
            ride_id = data.get("ride_id")
            lat = data.get("latitude")
            lon = data.get("longitude")
            if ride_id is None or lat is None or lon is None:
                return
            ride_group = f"ride_{ride_id}"
            # broadcast to ride group; handler below will forward to clients
            await self.channel_layer.group_send(
                ride_group,
                {
                    "type": "tracking_broadcast",
                    "user_id": self.user_id,
                    "latitude": float(lat),
                    "longitude": float(lon),
                },
            )
            return

        # OPTIONAL: driver accepting via websockets instead of HTTP
        if msg_type == "accept_offer" and self.role == "driver":
            ride_id = data.get("ride_id")
            if ride_id is None:
                await self.send_json({"type": "error", "message": "ride_id required"})
                return

            # 1. Update DB (mark accepted)
            accepted = await self._accept_ride_in_db(ride_id, self.user_id)

            if not accepted:
                # ride was not pending (already cancelled/accepted/expired)
                await self.send_json(
                    {
                        "type": "offer_accept_failed",
                        "ride_id": ride_id,
                        "message": "Ride is no longer available",
                    }
                )
                return

            # 2. Get passenger id and ride data
            ride_data = await self._get_ride_data(ride_id)
            passenger_id = ride_data["passenger_id"]

            # 3. Notify passenger
            # FIX: send to user_<id> group (this is what connect() actually uses)
            await self.channel_layer.group_send(
                f"user_{passenger_id}",
                {
                    "type": "ride_accepted",
                    "ride_id": ride_id,
                    "driver_id": self.user_id,
                    "ride_data": ride_data,
                },
            )

            # 4. Add THIS driver connection to ride group (for tracking)
            await self.channel_layer.group_add(f"ride_{ride_id}", self.channel_name)
            self.joined_rides.add(f"ride_{ride_id}")
            self.current_ride_id = ride_id

            # NOTE: we do NOT try to add passenger to ride group here.
            # Passenger will join via "start_tracking" when opening tracking screen.

            # 5. Tell driver that acceptance has been processed
            await self.send_json(
                {
                    "type": "offer_accepted",
                    "ride_id": ride_id,
                }
            )

            return

        if msg_type == "reject_offer" and self.role == "driver":
            ride_id = data.get("ride_id")
            offer_id = data.get("offer_id")
            await self.send_json(
                {"type": "offer_rejected", "ride_id": ride_id, "offer_id": offer_id}
            )
            return

        # default: ignore unsupported message types
        logger.debug("Unhandled WS message type=%s from user=%s", msg_type, self.user_id)

    # ----------------- handlers for group_send events (server to client)-----------------
    # These are invoked by channel_layer.group_send where "type" maps to method name

    async def ride_offer(self, event):
        """
        Sent by server to a driver to offer a ride.
        Usage server-side:
            await channel_layer.group_send(f"driver_{driver_id}", {
                "type": "ride_offer",
                "ride_data": {...},
                "offer_id": 123
            })
        """
        await self.send_json({
            "type": "new_ride_request",
            "ride": event.get("ride_data"),
            "offer_id": event.get("offer_id")
        })

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

    async def tracking_broadcast(self, event):
        # forwarded to clients who joined ride_<id> group
        await self.send_json(
            {
                "type": "tracking_update",
                "user_id": event.get("user_id"),
                "latitude": event.get("latitude"),
                "longitude": event.get("longitude"),
            }
        )

    # ----------------- small helpers interacting with DB -----------------
    async def send_json(self, content):
        """convenience wrapper to always send JSON"""
        try:
            await self.send(text_data=json.dumps(content))
        except Exception:
            logger.exception("Failed to send JSON to user %s", self.user_id)


    @database_sync_to_async
    def _update_driver_location_db(self, lat, lon):
        # update the driver's DriverProfile (safely)
        try:
            profile = self.user.driver_profile
            profile.current_latitude = lat
            profile.current_longitude = lon
            from django.utils import timezone

            profile.last_location_update = timezone.now()
            profile.save(
                update_fields=["current_latitude", "current_longitude", "last_location_update"]
            )
            return True
        except Exception:
            logger.exception("Failed to update driver profile for %s", self.user_id)
            return False

    @database_sync_to_async
    def _update_driver_status_db(self, status):
        try:
            profile = self.user.driver_profile
            profile.status = status
            profile.save(update_fields=["status"])
            return True
        except Exception:
            logger.exception("Failed to update driver status for %s", self.user_id)
            return False

    @database_sync_to_async
    def _get_driver_location(self):
        try:
            profile = self.user.driver_profile
            return {
                "latitude": float(profile.current_latitude)
                if profile.current_latitude is not None
                else None,
                "longitude": float(profile.current_longitude)
                if profile.current_longitude is not None
                else None,
            }
        except Exception:
            return {"latitude": None, "longitude": None}

    @database_sync_to_async
    def _accept_ride_in_db(self, ride_id, driver_id):
        from .models import RideRequest
        from django.utils import timezone
        try:
            ride = RideRequest.objects.get(id=ride_id)
        except RideRequest.DoesNotExist:
            return False

        # Only allow accepting if ride is still pending
        if ride.status != 'pending':
            return False

        ride.status = "accepted"
        # if driver is FK to User, assigning ID is fine.
        ride.driver_id = driver_id
        ride.accepted_at = timezone.now()
        ride.save(update_fields=["status", "driver", "accepted_at"])
        return True

    @database_sync_to_async
    def _get_ride_data(self, ride_id):
        from .models import RideRequest

        ride = RideRequest.objects.get(id=ride_id)
        return {
            "id": ride_id,
            "pickup_latitude": float(ride.pickup_latitude),
            "pickup_longitude": float(ride.pickup_longitude),
            "pickup_address": ride.pickup_address,
            "dropoff_address": ride.dropoff_address,
            "number_of_passengers": ride.number_of_passengers,
            "status": ride.status,
            # FIX: use *_id to get raw PK instead of model instance
            "passenger_id": ride.passenger_id,
            "driver_id": ride.driver_id,
        }