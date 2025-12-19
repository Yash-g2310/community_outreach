# Realtime App - Redis GEO-Based Driver Location System

## Overview

This app provides real-time driver location tracking and broadcasting using Redis GEO for fast geospatial queries and geohash-partitioned pub/sub for efficient updates.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        DRIVER FLOW                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Driver App ──WebSocket──▶ DriverConsumer                       │
│       │                         │                                │
│       │ location update         │                                │
│       │ (lat, lon)              ▼                                │
│       │                   broadcast.py                           │
│       │                         │                                │
│       │                         ├──▶ Redis GEO (GEOADD)          │
│       │                         │    - Fast geospatial index     │
│       │                         │    - GEORADIUS queries         │
│       │                         │                                │
│       │                         ├──▶ Redis Hash (driver meta)    │
│       │                         │    - username, vehicle_number  │
│       │                         │    - status, geohash           │
│       │                         │                                │
│       │                         └──▶ Lookup passengers in        │
│       │                              affected geohash tiles      │
│       │                                      │                   │
│       │                                      ▼                   │
│       │                              WebSocket.send() to         │
│       │                              each nearby passenger       │
│       │                                                          │
└───────┴──────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                      PASSENGER FLOW                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Passenger App ──WebSocket──▶ PassengerConsumer                  │
│       │                              │                           │
│       │ subscribe_nearby             │                           │
│       │ (lat, lon, radius)           ▼                           │
│       │                        geo.py service                    │
│       │                              │                           │
│       │                              ├──▶ Calculate covering     │
│       │                              │    geohash tiles          │
│       │                              │                           │
│       │                              ├──▶ Store subscription     │
│       │                              │    in Redis               │
│       │                              │                           │
│       │                              └──▶ GEORADIUS for initial  │
│       │                                   nearby drivers         │
│       │                                          │               │
│       │ ◀───────── Initial driver snapshot ──────┘               │
│       │                                                          │
│       │ ◀───────── Continuous updates from broadcast.py          │
│       │            (only drivers in subscribed geohashes)        │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## Key Components

### `geo.py` - Redis GEO Service

The core geospatial service that manages:

- **Driver Locations**: Uses `GEOADD` to index driver positions
- **Nearby Queries**: Uses `GEORADIUS` for fast proximity searches
- **Passenger Subscriptions**: Stores which geohash tiles each passenger is subscribed to
- **Geohash Encoding**: Converts lat/lon to geohash strings for channel partitioning

```python
from realtime.geo import get_driver_location_service

service = get_driver_location_service()

# Update driver location
result = service.update_driver_location(
    driver_id=123,
    lat=28.6139,
    lon=77.2090,
    username="John",
    vehicle_number="DL01AB1234",
    status="available"
)

# Query nearby drivers
drivers = service.get_nearby_drivers(lat=28.6139, lon=77.2090, radius_meters=1500)

# Subscribe passenger to area
result = service.subscribe_passenger_to_area(
    passenger_id=456,
    channel_name="specific.channel.name",
    lat=28.6139,
    lon=77.2090,
    radius_meters=1500
)
```

### `broadcast.py` - Geohash-Partitioned Broadcasting

Handles efficient broadcasting of driver updates:

- **Rate Limiting**: Prevents flooding (min 10m movement, max 2 updates/sec)
- **Geohash Channels**: Publishes to geohash-partitioned channels
- **Targeted Delivery**: Only sends to passengers in relevant geohash tiles

```python
from realtime.broadcast import broadcast_driver_location, broadcast_driver_status

# Broadcast location update
result = broadcast_driver_location(
    driver_id=123,
    lat=28.6139,
    lon=77.2090,
    username="John",
    vehicle_number="DL01AB1234"
)
# Returns: {"broadcasted": True, "passengers_notified": 5, "geohash": "ttnfv2"}

# Broadcast status change
result = broadcast_driver_status(
    driver_id=123,
    status="offline"
)
```

### `consumers/` - WebSocket Consumers

- **DriverConsumer**: Handles driver location updates, status changes
- **PassengerConsumer**: Handles nearby driver subscriptions, receives updates
- **RideConsumer**: Handles active ride tracking

## Redis Data Structure

```
# Driver GEO Index (sorted set with geo encoding)
drivers:geo
  └── driver_id → (longitude, latitude)

# Driver Metadata (hash per driver)
driver:meta:{driver_id}
  ├── driver_id
  ├── username
  ├── vehicle_number
  ├── status (available/busy/offline)
  ├── latitude
  ├── longitude
  └── geohash

# Active Drivers Set
drivers:online
  └── {driver_id, driver_id, ...}

# Passenger Subscriptions (hash per passenger)
passenger:subs:{passenger_id}
  ├── channel_name (WebSocket channel)
  ├── latitude
  ├── longitude
  ├── radius
  └── geohashes (comma-separated list)
```

## Geohash Precision

| Precision | Cell Size | Use Case |
|-----------|-----------|----------|
| 5 | ~4.9km × 4.9km | Large city areas |
| 6 | ~1.2km × 0.6km | Neighborhood level (default) |
| 7 | ~150m × 150m | Block level |

The default precision is 6, which creates tiles of approximately 1.2km × 0.6km. This provides a good balance between:
- Granularity (users only receive updates from nearby drivers)
- Efficiency (not too many channels to manage)

## Configuration

In `settings.py`:

```python
# Redis GEO URL (can use separate DB from Celery)
REDIS_GEO_URL = 'redis://localhost:6379/1'

# Channels layer (must use Redis for multi-server deployments)
CHANNEL_LAYERS = {
    "default": {
        "BACKEND": "channels_redis.core.RedisChannelLayer",
        "CONFIG": {
            "hosts": [("localhost", 6379)],
        },
    },
}

# Optional GEO configuration overrides
REDIS_GEO_CONFIG = {
    "GEOHASH_PRECISION": 6,
    "DRIVER_LOCATION_TTL": 120,
    "MIN_UPDATE_DISTANCE_METERS": 10,
    "MAX_UPDATES_PER_SECOND": 2,
}
```

## Frontend Integration

### Driver App (Flutter)

```dart
// Send location updates via WebSocket
void sendLocationUpdate(double lat, double lon) {
  _socket.sink.add(jsonEncode({
    "type": "driver_location_update",
    "latitude": lat,
    "longitude": lon,
  }));
}

// Handle throttling on client side
// - Only send if moved > 10 meters
// - Max 1 update per 1-3 seconds
```

### Passenger App (Flutter)

```dart
// Subscribe to nearby drivers
void subscribeNearby(double lat, double lon, int radius) {
  _socket.sink.add(jsonEncode({
    "type": "subscribe_nearby",
    "latitude": lat,
    "longitude": lon,
    "radius": radius,
  }));
}

// Handle incoming updates
void handleMessage(dynamic message) {
  final data = jsonDecode(message);
  
  switch (data['type']) {
    case 'driver_location_updated':
      updateDriverMarker(
        data['driver_id'],
        data['latitude'],
        data['longitude'],
        data['vehicle_number'],
      );
      break;
    case 'driver_status_changed':
      if (data['status'] == 'offline') {
        removeDriverMarker(data['driver_id']);
      }
      break;
  }
}

// Smooth marker animation
// - Interpolate between positions
// - Use requestAnimationFrame equivalent
// - Throttle UI redraws (max 5/sec)
```

## Performance Optimizations

1. **Rate Limiting**: Drivers' updates are rate-limited (min 10m movement, max 2/sec)
2. **Geohash Partitioning**: Updates only go to passengers in relevant tiles
3. **Redis GEO**: O(log N) complexity for radius queries
4. **TTL Cleanup**: Stale data automatically expires
5. **Periodic DB Writes**: Only persist to PostgreSQL periodically, not on every update

## Scaling

For high-scale deployments:

1. **Redis Cluster**: Shard by geography using consistent hashing
2. **Multiple WS Servers**: Stateless, any server can handle any connection
3. **Kafka/Streams**: For guaranteed delivery and replay capability
4. **PostGIS**: For historical queries and analytics (periodic flush from Redis)

## Migration from In-Memory

The previous implementation used an in-memory `ACTIVE_PASSENGERS` dictionary. The new Redis-based system provides:

- ✅ Persistence across server restarts
- ✅ Shared state across multiple WS server instances
- ✅ Geohash-based channel partitioning for efficient broadcasts
- ✅ Automatic TTL-based cleanup
- ✅ Fast GEORADIUS queries instead of O(N) distance calculations
