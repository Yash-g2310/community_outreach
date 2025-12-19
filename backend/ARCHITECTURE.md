# Backend Architecture

## Overview

This is a Django-based backend for the E-Rick Community Outreach application. It provides REST APIs for ride management, WebSocket connections for real-time updates, and uses Redis GEO for efficient driver location tracking.

## Directory Structure

```
backend/
├── app_backend/          # Django project configuration
│   ├── settings/         # Settings module
│   ├── asgi.py          # ASGI config with WebSocket routing
│   ├── celery.py        # Celery configuration
│   └── urls.py          # Root URL configuration
│
├── accounts/             # User authentication and profiles
│   ├── models.py        # CustomUser model (base for all users)
│   ├── views.py         # Auth endpoints (register, login, profile)
│   ├── serializers.py   # User serialization
│   └── urls.py          # Auth URLs
│
├── drivers/              # Driver-specific functionality
│   ├── models.py        # DriverProfile model
│   ├── views.py         # Driver REST endpoints
│   ├── services.py      # Driver business logic
│   ├── serializers.py   # Driver serialization
│   └── urls.py          # Driver URLs
│
├── passengers/           # Passenger-specific functionality
│   ├── models.py        # (currently empty, uses CustomUser)
│   ├── views/           # Split view modules
│   │   ├── rides.py     # Ride-related endpoints
│   │   └── info.py      # Profile/info endpoints
│   ├── services/        # Business logic
│   │   ├── ride_services.py   # Ride request handling
│   │   └── info_services.py   # Profile operations
│   └── urls.py          # Passenger URLs
│
├── rides/                # Ride models and REST APIs
│   ├── models.py        # RideRequest, RideOffer models
│   ├── views.py         # Ride REST endpoints
│   ├── serializers.py   # Ride serialization
│   ├── tasks.py         # Celery tasks (offer expiry)
│   ├── services/        # Legacy services (deprecated)
│   └── urls.py          # Ride URLs
│
├── realtime/             # WebSocket and real-time features
│   ├── consumers/       # WebSocket consumers
│   │   ├── driver_consumer.py    # Driver WebSocket handler
│   │   ├── passenger_consumer.py # Passenger WebSocket handler
│   │   └── ride_consumer.py      # Ride status WebSocket handler
│   ├── geo.py           # Redis GEO service for location tracking
│   ├── broadcast.py     # Geohash-based broadcast service
│   ├── notifications.py # WebSocket notification helpers
│   ├── middleware.py    # JWT authentication for WebSockets
│   ├── routing.py       # WebSocket URL routing
│   └── README.md        # Detailed realtime architecture docs
│
├── common/               # Shared utilities (NOT a Django app)
│   └── utils/
│       └── geo.py       # Geographic utilities (Haversine, geohash)
│
├── services/             # Business logic layer (NOT a Django app)
│   ├── matching/        # Driver matching service
│   │   ├── offer_builder.py    # Build ordered offer queues
│   │   └── offer_dispatch.py   # Dispatch offers to drivers
│   └── ride_management/ # Ride lifecycle service
│       ├── ride_lifecycle.py   # Core ride operations
│       └── exceptions.py       # Custom exceptions
│
└── media/               # Uploaded files (profile pictures, etc.)
```

## Key Concepts

### 1. User Roles

Users have a `role` field: `'user'` (passenger) or `'driver'`.

- **Passengers**: Book rides, track drivers, receive updates
- **Drivers**: Accept rides, update location, complete rides

### 2. Ride Lifecycle

```
pending → accepted → completed
    ↓         ↓
  cancelled_user  cancelled_driver
    ↓
  no_drivers (all offers expired)
```

### 3. Daisy-Chain Offer Pattern

When a ride is requested:

1. System finds all available drivers within broadcast radius
2. Sorts drivers by distance (closest first)
3. Creates `RideOffer` records (ordered queue)
4. Sends offer to first driver
5. If driver doesn't respond in 20s, Celery task expires offer
6. System sends to next driver in queue
7. Repeats until a driver accepts or queue is exhausted

### 4. Redis GEO for Location Tracking

Drivers' locations are stored in Redis using GEO commands:

- `GEOADD` - Store driver position
- `GEORADIUS` - Find nearby drivers
- Geohash-based pub/sub for efficient broadcasting

### 5. WebSocket Architecture

Three consumer types:

- **DriverConsumer** (`/ws/driver/`): Location updates, ride offers
- **PassengerConsumer** (`/ws/passenger/`): Driver locations, ride status
- **RideConsumer** (`/ws/rides/{ride_id}/`): Real-time ride tracking

## Import Patterns

### Use services layer for business logic:

```python
# Good - uses services layer
from services.matching import build_offers_for_ride, dispatch_next_offer
from services.ride_management import create_ride_request, accept_ride

# Good - uses common utilities
from common.utils.geo import calculate_distance, encode_geohash
```

### Use realtime for WebSocket notifications:

```python
from realtime.notifications import notify_driver_event, notify_passenger_event
from realtime.broadcast import broadcast_driver_location
```

### Deprecated patterns (backward compatible but not recommended):

```python
# Deprecated - use services.matching instead
from realtime.notifications import build_offers_for_ride

# Deprecated - use common.utils.geo instead
from realtime.utils import calculate_distance

# Deprecated - files kept only for backward compatibility
from rides.consumers import *  # Use realtime.consumers
from rides.notifications import *  # Use realtime.notifications
from rides.utils import *  # Use common.utils.geo
```

## Configuration

### Environment Variables

```bash
# Django
SECRET_KEY=your-secret-key
DEBUG=True
ALLOWED_HOSTS=localhost,127.0.0.1

# Redis
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_GEO_DB=1  # Separate DB for GEO data

# Celery
CELERY_BROKER_URL=redis://localhost:6379/0
```

### Redis GEO Settings (settings.py)

```python
REDIS_GEO_CONFIG = {
    "host": os.getenv("REDIS_HOST", "localhost"),
    "port": int(os.getenv("REDIS_PORT", 6379)),
    "db": int(os.getenv("REDIS_GEO_DB", 1)),
    "decode_responses": True,
    "socket_timeout": 5,
}

DRIVER_BROADCAST_CONFIG = {
    "min_distance_meters": 10,
    "rate_limit_seconds": 0.5,
    "geohash_precision": 6,
    "default_search_radius_km": 5,
}
```

## Running the Application

### Development

```bash
# Terminal 1: Django
python manage.py runserver

# Terminal 2: Redis
redis-server

# Terminal 3: Celery worker
celery -A app_backend worker -l info

# Terminal 4: Celery beat (optional, for scheduled tasks)
celery -A app_backend beat -l info
```

### WebSocket Testing

```javascript
// Connect as driver
const ws = new WebSocket('ws://localhost:8000/ws/driver/?token=<jwt>');

// Send location update
ws.send(JSON.stringify({
    type: 'location_update',
    latitude: 12.9716,
    longitude: 77.5946
}));
```

## API Endpoints

### Authentication
- `POST /api/accounts/register/` - Register new user
- `POST /api/accounts/login/` - Login and get JWT tokens
- `POST /api/accounts/token/refresh/` - Refresh access token

### Drivers
- `GET /api/drivers/profile/` - Get driver profile
- `PATCH /api/drivers/profile/` - Update profile
- `POST /api/drivers/status/` - Update availability status
- `GET /api/drivers/rides/` - Get ride history

### Passengers
- `GET /api/passengers/profile/` - Get passenger profile
- `PATCH /api/passengers/profile/` - Update profile
- `GET /api/passengers/nearby-drivers/` - Find nearby drivers
- `GET /api/passengers/rides/` - Get ride history

### Rides
- `POST /api/rides/request/` - Request a new ride
- `GET /api/rides/current/` - Get current active ride
- `POST /api/rides/{id}/cancel/` - Cancel ride (passenger)
- `POST /api/rides/{id}/accept/` - Accept ride (driver)
- `POST /api/rides/{id}/reject/` - Reject ride offer (driver)
- `POST /api/rides/{id}/complete/` - Complete ride (driver)
- `POST /api/rides/{id}/driver-cancel/` - Cancel ride (driver)

## Testing

```bash
# Run all tests
python manage.py test

# Run specific app tests
python manage.py test rides
python manage.py test realtime
```
