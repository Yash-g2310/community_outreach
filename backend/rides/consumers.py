import json
from channels.generic.websocket import AsyncWebsocketConsumer
from channels.db import database_sync_to_async
from django.contrib.auth import get_user_model
from .models import RideRequest, DriverProfile

User = get_user_model()


class RideNotificationConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer for drivers to receive nearby ride requests
    
    Connection URL: ws://localhost:8000/ws/driver/rides/
    
    When a passenger creates a ride request, this broadcasts it to all
    available drivers within the broadcast radius.
    """
    
    async def connect(self):
        # Check if user is authenticated and is a driver
        self.user = self.scope["user"]
        
        if self.user.is_anonymous:
            await self.close()
            return
        
        if self.user.role != 'driver':
            await self.close()
            return
        
        # Add driver to the 'drivers' group to receive ride notifications
        self.driver_group = 'available_drivers'
        await self.channel_layer.group_add(
            self.driver_group,
            self.channel_name
        )
        
        await self.accept()
        
        # Send connection confirmation
        await self.send(text_data=json.dumps({
            'type': 'connection_established',
            'message': 'Connected to ride notifications'
        }))
    
    async def disconnect(self, close_code):
        # Remove from driver group
        if hasattr(self, 'driver_group'):
            await self.channel_layer.group_discard(
                self.driver_group,
                self.channel_name
            )
    
    async def receive(self, text_data):
        """Handle messages from driver (e.g., updating availability status)"""
        try:
            data = json.loads(text_data)
            message_type = data.get('type')
            
            if message_type == 'ping':
                # Keep-alive ping
                await self.send(text_data=json.dumps({
                    'type': 'pong',
                    'message': 'Connection alive'
                }))
        except json.JSONDecodeError:
            pass
    
    async def new_ride_request(self, event):
        """
        Called when a new ride request is broadcast to drivers
        Receives event from channel layer
        """
        await self.send(text_data=json.dumps({
            'type': 'new_ride_request',
            'ride': event['ride_data']
        }))
    
    async def ride_cancelled(self, event):
        """Notify drivers when a ride is cancelled"""
        await self.send(text_data=json.dumps({
            'type': 'ride_cancelled',
            'ride_id': event['ride_id'],
            'message': 'This ride request has been cancelled'
        }))
    
    async def ride_accepted(self, event):
        """Notify drivers when a ride has been accepted by another driver"""
        await self.send(text_data=json.dumps({
            'type': 'ride_accepted',
            'ride_id': event['ride_id'],
            'message': 'This ride has been accepted by another driver'
        }))


class RideTrackingConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer for real-time location tracking during active rides
    
    Connection URLs:
    - Passenger: ws://localhost:8000/ws/ride/{ride_id}/passenger/
    - Driver: ws://localhost:8000/ws/ride/{ride_id}/driver/
    
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
        self.ride_group = f'ride_{self.ride_id}'
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
                # Broadcast location to everyone in the ride group
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
                # Broadcast ride status changes (started, completed, etc.)
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
