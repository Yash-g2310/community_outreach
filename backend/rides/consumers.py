"""Contains WebSocket handlers that deliver messages to clients"""

import json
import logging
from typing import Dict, Any
from channels.generic.websocket import AsyncWebsocketConsumer
from channels.db import database_sync_to_async
from django.contrib.auth import get_user_model
from .models import RideRequest, DriverProfile
from utils import calculate_distance

User = get_user_model()


class RideNotificationConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer for drivers to receive ride request offers sequentially.
    
    Connection URL: ws://localhost:8000/ws/driver/rides/?token=<JWT>

    Each driver is connected to their own group:
        driver_<driver_id>

    Server dispatches ride offers one-by-one by sending messages to:
        group_send("driver_<driver_id>", event)
    """

    async def connect(self):
        self.user = self.scope["user"]
        
        if self.user.is_anonymous:
            await self.close()
            return
        
        if self.user.role != 'driver':
            await self.close()
            return
        
        self.driver_group = f"driver_{self.user.id}"

        # Connect this socket to its personal driver group
        await self.channel_layer.group_add(
            self.driver_group,
            self.channel_name
        )

        await self.accept()

        await self.send_json({
            "type": "connection_established",
            "message": "Connected to ride notifications"
        })

    async def disconnect(self, close_code):
        try:
            await self.channel_layer.group_discard(
                self.driver_group,
                self.channel_name
            )
        except Exception:
            pass

    async def receive(self, text_data):
        """
        Drivers may send:
            {"type": "ping"}
        """
        try:
            data = json.loads(text_data)
        except json.JSONDecodeError:
            return

        if data.get("type") == "ping":
            await self.send_json({
                "type": "pong",
                "message": "Connection alive"
            })

    async def new_ride_request(self, event):
        """
        Server sends directly to this driver only (no filtering needed):
            group_send("driver_<id>", {"type": "new_ride_request", "ride_data": {...}})
        """
        ride_data = event.get("ride_data")
        if not ride_data:
            return

        await self.send_json({
            "type": "new_ride_request",
            "ride": ride_data
        })

    async def ride_cancelled(self, event):
        await self.send_json({
            "type": "ride_cancelled",
            "ride_id": event.get("ride_id"),
            "message": "This ride request has been cancelled"
        })

    async def ride_accepted(self, event):
        await self.send_json({
            "type": "ride_accepted",
            "ride_id": event.get("ride_id"),
            "message": "This ride has been accepted by another driver"
        })

    async def ride_expired(self, event):
        await self.send_json({
            "type": "ride_expired",
            "ride_id": event.get("ride_id"),
            "message": event.get("message", "This ride offer has timed out")
        })


class RideTrackingConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer for real-time location tracking during active rides
    
    Connection URLs:
    - Passenger: ws://localhost:8000/ws/ride/{ride_id}/passenger/
    - Driver: ws://localhost:8000/ws/ride/{ride_id}/driver/
    
    Passenger WebSocket ----\
                             >--- server group "{ride_id}" --- broadcast ----> all in group
    Driver WebSocket -------/

    Both passenger and driver connect to track each other's location.
    """
    
    async def connect(self):
        self.user = self.scope["user"]
        self.ride_id = self.scope['url_route']['kwargs']['ride_id']
        self.user_type = self.scope['url_route']['kwargs']['user_type']  # 'passenger' or 'driver'
        
        if self.user.is_anonymous:
            await self.close()
            return
        
        # Verify user has access to this ride
        has_access = await self.verify_ride_access()
        if not has_access:
            await self.close()
            return
        
        # Join ride-specific group
        self.ride_group = f'ride_{self.ride_id}'  # Passenger & Driver share the same group as {ride_id} is same for both
        await self.channel_layer.group_add(
            self.ride_group,
            self.channel_name
        )
        
        await self.accept()
        
        await self.send(text_data=json.dumps({
            'type': 'connection_established',
            'message': f'Connected to ride {self.ride_id} tracking',
            'user_type': self.user_type
        }))
    
    async def disconnect(self, close_code):
        # Leave ride group
        if hasattr(self, 'ride_group'):
            await self.channel_layer.group_discard(
                self.ride_group,
                self.channel_name
            )
    
    async def receive(self, text_data):
        """Handle location updates from driver or passenger"""
        try:
            data = json.loads(text_data)
            message_type = data.get('type')
            
            if message_type == 'location_update':
                await self.channel_layer.group_send(
                    self.ride_group,
                    {
                        'type': 'location_broadcast',
                        'user_type': self.user_type,
                        'latitude': data.get('latitude'),
                        'longitude': data.get('longitude'),
                        'timestamp': data.get('timestamp')
                    }
                )
            
            elif message_type == 'ride_status_update':
                await self.channel_layer.group_send(
                    self.ride_group,
                    {
                        'type': 'status_broadcast',
                        'status': data.get('status'),
                        'message': data.get('message', '')
                    }
                )
        
        except json.JSONDecodeError:
            pass
    
    async def location_broadcast(self, event):
        """Send location update to WebSocket"""
        await self.send(text_data=json.dumps({
            'type': 'location_update',
            'user_type': event['user_type'],
            'latitude': event['latitude'],
            'longitude': event['longitude'],
            'timestamp': event.get('timestamp')
        }))
    
    async def status_broadcast(self, event):
        """Send ride status update to WebSocket"""
        await self.send(text_data=json.dumps({
            'type': 'ride_status_update',
            'status': event['status'],
            'message': event.get('message', '')
        }))
    
    @database_sync_to_async
    def verify_ride_access(self):
        """Verify that the user has access to this ride"""
        try:
            ride = RideRequest.objects.get(id=self.ride_id)
            
            # Passenger can only access their own rides
            if self.user_type == 'passenger' and ride.passenger_id == self.user.id:
                return True
            
            # Driver can only access rides assigned to them
            if self.user_type == 'driver' and ride.driver_id == self.user.id:
                return True
            
            return False
        except RideRequest.DoesNotExist:
            return False


class PassengerRideStatusConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer for passengers to receive ride status updates
    
    Connection URL: ws://localhost:8000/ws/passenger/ride-status/
    
    Passengers connect to receive real-time updates about their ride requests
    (e.g., driver accepted, no drivers available, etc.)
    """
    
    async def connect(self):
        self.user = self.scope["user"]
        
        if self.user.is_anonymous:
            await self.close()
            return
        
        if self.user.role != 'user':
            await self.close()
            return
        
        # Add passenger to their personal notification group
        self.passenger_group = f'passenger_{self.user.id}'
        await self.channel_layer.group_add(
            self.passenger_group,
            self.channel_name
        )
        
        await self.accept()
        
        await self.send(text_data=json.dumps({
            'type': 'connection_established',
            'message': 'Connected to ride status updates'
        }))
    
    async def disconnect(self, close_code):
        # Remove from passenger group
        if hasattr(self, 'passenger_group'):
            await self.channel_layer.group_discard(
                self.passenger_group,
                self.channel_name
            )
    
    async def receive(self, text_data):
        """Handle messages from passenger (e.g., ping)"""
        try:
            data = json.loads(text_data)
            message_type = data.get('type')
            
            if message_type == 'ping':
                await self.send(text_data=json.dumps({
                    'type': 'pong',
                    'message': 'Connection alive'
                }))
        except json.JSONDecodeError:
            pass
    
    async def no_drivers_available(self, event):
        """Notify passenger when no drivers accepted their ride request"""
        await self.send(text_data=json.dumps({
            'type': 'no_drivers_available',
            'ride_id': event['ride_id'],
            'status': event['status'],
            'message': event.get('message', 'No drivers are available at the moment'),
            'ride': event.get('ride_data', {})
        }))
    
    async def ride_accepted_by_driver(self, event):
        """Notify passenger when a driver accepts their ride"""
        await self.send(text_data=json.dumps({
            'type': 'ride_accepted',
            'ride_id': event['ride_id'],
            'status': event['status'],
            'message': event.get('message', 'A driver has accepted your ride!'),
            'ride': event.get('ride_data', {})
        }))

# TODO: Below code is completely wrong as per the Approach, needs to be re-written
class NearbyDriversConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer for passengers to receive real-time updates about nearby drivers
    
    Connection URL: ws://localhost:8000/ws/passenger/nearby-drivers/
    
    Broadcasts when:
    - A driver goes online/offline
    - A driver's location changes significantly
    """
    
    async def connect(self):
        self.user = self.scope["user"]
        
        if self.user.is_anonymous:
            await self.close()
            return
        
        if self.user.role != 'user':
            await self.close()
            return
        
        # Add passenger to the 'passengers' group to receive driver status updates
        self.passengers_group = 'all_passengers'
        await self.channel_layer.group_add(
            self.passengers_group,
            self.channel_name
        )
        
        await self.accept()
        
        await self.send(text_data=json.dumps({
            'type': 'connection_established',
            'message': 'Connected to nearby drivers updates'
        }))
    
    async def disconnect(self, close_code):
        # Remove from passengers group
        if hasattr(self, 'passengers_group'):
            await self.channel_layer.group_discard(
                self.passengers_group,
                self.channel_name
            )
    
    async def receive(self, text_data):
        """Handle messages from passenger (e.g., ping)"""
        try:
            data = json.loads(text_data)
            message_type = data.get('type')
            
            if message_type == 'ping':
                await self.send(text_data=json.dumps({
                    'type': 'pong',
                    'message': 'Connection alive'
                }))
        except json.JSONDecodeError:
            pass
    
    async def driver_status_changed(self, event):
        """Notify passengers when a driver goes online/offline"""
        await self.send(text_data=json.dumps({
            'type': 'driver_status_changed',
            'driver_id': event['driver_id'],
            'status': event['status'],
            'latitude': event.get('latitude'),
            'longitude': event.get('longitude'),
            'message': event.get('message', '')
        }))
    
    async def driver_location_updated(self, event):
        """Notify passengers when a driver's location changes significantly"""
        await self.send(text_data=json.dumps({
            'type': 'driver_location_updated',
            'driver_id': event['driver_id'],
            'latitude': event['latitude'],
            'longitude': event['longitude']
        }))


logger = logging.getLogger(__name__)

ACTIVE_PASSENGERS: Dict[int, Dict[str, Any]] = {}

# Helper used by server-side code: call this to notify nearby passengers (async)
async def notify_nearby_passengers_async(channel_layer, driver_id: int, lat: float, lon: float, event_type: str = "driver_location_updated", radius_override: int = None, extra: Dict[str, Any] = None):
    """
    Notify connected passengers whose subscription radius includes driver's location.
    - channel_layer: get_channel_layer()
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
                # Send direct to passenger's channel name
                payload = {
                    "type": event_type,
                    "driver_id": driver_id,
                    "latitude": lat,
                    "longitude": lon,
                }
                payload.update(extra)
                await channel_layer.send(info["channel_name"], payload)
        except Exception:
            logger.exception("notify_nearby_passengers_async error for passenger %s", pid)


# Synchronous wrapper (use from sync views)
def notify_nearby_passengers_sync(channel_layer, driver_id: int, lat: float, lon: float, event_type: str = "driver_location_updated", radius_override: int = None, extra: Dict[str, Any] = None):
    import asyncio
    asyncio.run(notify_nearby_passengers_async(channel_layer, driver_id, lat, lon, event_type, radius_override, extra))


# --- Unified AppConsumer ---
class AppConsumer(AsyncWebsocketConsumer):
    """
    Unified websocket consumer for drivers & passengers.
    Connect clients to a single endpoint:
        ws://.../ws/app/?token=<JWT>
    Messages use a 'type' field for routing.

    Incoming messages (examples):
     - {"type":"ping"}
     - {"type":"subscribe_nearby","latitude":12.97,"longitude":77.59,"radius":1000}   # passenger
     - {"type":"unsubscribe_nearby"}  # passenger
     - {"type":"driver_location_update","latitude":12.97,"longitude":77.59}           # driver
     - {"type":"driver_status_update","status":"available"}                           # driver
     - {"type":"start_tracking","ride_id":123}                                        # join ride group (driver/passenger)
     - {"type":"stop_tracking","ride_id":123}                                         # leave ride group
     - {"type":"tracking_update","ride_id":123,"latitude":12.97,"longitude":77.59}    # driver or passenger during ride
     - {"type":"accept_offer","ride_id":123,"offer_id":45}                            # driver (optional; handled by HTTP too)
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

        # driver personal group (alternative name)
        if self.role == "driver":
            self.driver_group = f"driver_{self.user_id}"
            await self.channel_layer.group_add(self.driver_group, self.channel_name)

        # ride groups the user has joined (set of ride_<id>)
        self.joined_rides = set()

        await self.accept()

        # send basic welcome
        await self.send_json({"type": "connection_established", "user_id": self.user_id, "role": self.role})

    async def disconnect(self, close_code):
        # remove from personal group(s)
        try:
            await self.channel_layer.group_discard(self.user_group, self.channel_name)
            if getattr(self, "driver_group", None):
                await self.channel_layer.group_discard(self.driver_group, self.channel_name)
            # remove passenger subscription
            if self.role == "user":
                ACTIVE_PASSENGERS.pop(self.user_id, None)
            # leave ride groups
            for rg in list(self.joined_rides):
                await self.channel_layer.group_discard(rg, self.channel_name)
        except Exception:
            logger.exception("Error during disconnect for user %s", self.user_id)

    # ----------------- incoming messages from client -----------------
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
                await self.send_json({"type": "error", "message": "subscribe_nearby requires latitude and longitude"})
                return
            ACTIVE_PASSENGERS[self.user_id] = {
                "channel_name": self.channel_name,
                "latitude": float(lat),
                "longitude": float(lon),
                "radius": int(radius)
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
                await self.send_json({"type": "error", "message": "driver_location_update requires lat/lon"})
                return

            # update DB profile (sync -> async wrapper)
            await self._update_driver_location_db(lat, lon)

            # notify nearby passengers (async helper)
            from channels.layers import get_channel_layer
            ch = get_channel_layer()
            await notify_nearby_passengers_async(ch, self.user_id, float(lat), float(lon), event_type="driver_location_updated")

            return

        if msg_type == "driver_status_update" and self.role == "driver":
            status = data.get("status")  # 'available' or 'offline'
            message = data.get("message", "")
            # update DB
            await self._update_driver_status_db(status)
            # optionally notify nearby passengers
            from channels.layers import get_channel_layer
            ch = get_channel_layer()
            # use driver's stored lat/lon if available
            profile = await self._get_driver_location()
            if profile:
                lat = profile.get("latitude")
                lon = profile.get("longitude")
                if lat is not None and lon is not None:
                    await notify_nearby_passengers_async(ch, self.user_id, float(lat), float(lon), event_type="driver_status_changed", extra={"status": status, "message": message})
            return

        # TRACKING: join/leave/emit tracking updates
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

        if msg_type == "tracking_update":
            ride_id = data.get("ride_id")
            lat = data.get("latitude")
            lon = data.get("longitude")
            if ride_id is None or lat is None or lon is None:
                return
            ride_group = f"ride_{ride_id}"
            # broadcast to ride group; handler below will forward to clients
            await self.channel_layer.group_send(ride_group, {
                "type": "tracking_broadcast",
                "user_id": self.user_id,
                "latitude": float(lat),
                "longitude": float(lon),
            })
            return

        # driver accepting/rejecting offers might be handled by HTTP endpoints.
        # Still, support optional messages:
        if msg_type == "accept_offer" and self.role == "driver":
            # server-side offer handling should update DB and notify passenger
            ride_id = data.get("ride_id")
            offer_id = data.get("offer_id")
            # notify server-side via DB or call service (not implemented here)
            await self.send_json({"type": "offer_accepted", "ride_id": ride_id, "offer_id": offer_id})
            return

        if msg_type == "reject_offer" and self.role == "driver":
            ride_id = data.get("ride_id")
            offer_id = data.get("offer_id")
            await self.send_json({"type": "offer_rejected", "ride_id": ride_id, "offer_id": offer_id})
            return

        # default: ignore unsupported message types
        logger.debug("Unhandled WS message type=%s from user=%s", msg_type, self.user_id)

    # ----------------- handlers for group_send events -----------------
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
        await self.send_json({
            "type": "ride_expired",
            "ride_id": event.get("ride_id"),
            "message": event.get("message", "Offer timed out")
        })

    async def ride_cancelled(self, event):
        await self.send_json({
            "type": "ride_cancelled",
            "ride_id": event.get("ride_id"),
            "message": event.get("message", "")
        })

    async def ride_accepted(self, event):
        # notify passenger that driver accepted (server may send to passenger group)
        await self.send_json({
            "type": "ride_accepted",
            "ride_id": event.get("ride_id"),
            "driver_id": event.get("driver_id"),
            "ride": event.get("ride_data", {})
        })

    async def no_drivers_available(self, event):
        await self.send_json({
            "type": "no_drivers_available",
            "ride_id": event.get("ride_id"),
            "message": event.get("message", "No drivers available")
        })

    async def driver_status_changed(self, event):
        # passengers receive this when driver toggles available/offline within radius
        await self.send_json({
            "type": "driver_status_changed",
            "driver_id": event.get("driver_id"),
            "status": event.get("status"),
            "latitude": event.get("latitude"),
            "longitude": event.get("longitude"),
            "message": event.get("message", "")
        })

    async def driver_location_updated(self, event):
        await self.send_json({
            "type": "driver_location_updated",
            "driver_id": event.get("driver_id"),
            "latitude": event.get("latitude"),
            "longitude": event.get("longitude")
        })

    async def tracking_broadcast(self, event):
        # forwarded to clients who joined ride_<id> group
        await self.send_json({
            "type": "tracking_update",
            "user_id": event.get("user_id"),
            "latitude": event.get("latitude"),
            "longitude": event.get("longitude")
        })

    # ----------------- small helpers interacting with DB -----------------
    @database_sync_to_async
    def _update_driver_location_db(self, lat, lon):
        # update the driver's DriverProfile (safely)
        from .models import DriverProfile
        try:
            profile = self.user.driver_profile
            profile.current_latitude = lat
            profile.current_longitude = lon
            from django.utils import timezone
            profile.last_location_update = timezone.now()
            profile.save(update_fields=["current_latitude", "current_longitude", "last_location_update"])
            return True
        except Exception:
            logger.exception("Failed to update driver profile for %s", self.user_id)
            return False

    @database_sync_to_async
    def _update_driver_status_db(self, status):
        from .models import DriverProfile
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
                "latitude": float(profile.current_latitude) if profile.current_latitude is not None else None,
                "longitude": float(profile.current_longitude) if profile.current_longitude is not None else None
            }
        except Exception:
            return {"latitude": None, "longitude": None}

    # convenience wrapper to always send JSON through channels
    async def send_json(self, content):
        try:
            await self.send(text_data=json.dumps(content))
        except Exception:
            logger.exception("Failed to send JSON to user %s", self.user_id)