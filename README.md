# E-Rick Connect

E-Rick Connect is a Flutter rider/driver application backed by a FastAPI ride service. The current MVP covers local authentication, driver availability, nearby-driver discovery, ride-request matching, ride lifecycle actions, and live participant tracking.

Payments, fare calculation, ratings, promotions, push notifications, and profile-image storage are not implemented in the current service boundary.

## Repository map

| Area | Location | Documentation |
| --- | --- | --- |
| Backend API, database models, migrations, and live events | [`backend/`](backend/) | [`backend/README.md`](backend/README.md) |
| Flutter mobile/web client | [`erick_connect_app/`](erick_connect_app/) | [`erick_connect_app/README.md`](erick_connect_app/README.md) |
| Generated/build output | `build/` and platform build folders | Do not edit by hand |

## System design

```mermaid
flowchart LR
    Rider["Flutter rider client"]
    Driver["Flutter driver client"]
    API["FastAPI API - REST and authenticated live events"]
    DB["PostgreSQL and PostGIS - durable data and audit history"]
    Redis["Redis - availability state and geo index"]
    Expiry["FastAPI lifespan task - search expiry loop"]
    Tiles["OpenStreetMap tile service"]

    Rider -->|REST| API
    Driver -->|REST| API
    Rider -->|live events| API
    Driver -->|live events| API
    API -->|durable data| DB
    API -->|availability and geo search| Redis
    Expiry -->|expire searches| DB
    Expiry -->|send expiry events| API
    Rider -->|map tiles| Tiles
    Driver -->|map tiles| Tiles
```

The server is the source of truth for authentication, ride state, and active-ride snapshots. Redis is used for fast driver availability and proximity lookup; accepted-ride state and the latest participant locations are persisted in PostgreSQL. WebSocket connections are authenticated with the same JWT access token used by REST.

## Main user flows

### Ride request and matching

```mermaid
sequenceDiagram
    participant R as Rider app
    participant A as FastAPI
    participant X as Redis
    participant D as Driver app
    participant P as PostgreSQL

    R->>A: GET nearby-drivers
    A->>X: Query available geo index
    X-->>A: Anonymous nearby coordinates
    A-->>R: Driver pins
    R->>A: Create ride request
    A->>X: Find available drivers in radius
    A->>P: Store ride and recipient rows
    A-->>D: ride_request over WebSocket
    D->>A: POST accept
    A->>P: Lock ride and accept first winner
    A-->>R: ride_accepted
    A-->>D: ride_accepted
    R->>A: Active ride snapshot and location
    A-->>R: Live ride events
    D->>A: Lifecycle actions and location
    A-->>D: Live ride events
```

Ride requests start as `searching`. The configured search timeout expires unanswered requests; the first eligible driver to accept wins, other recipients are closed, and the winning driver becomes busy.

## Local development

### Prerequisites

- Python 3.11+ with a virtual environment.
- Flutter/Dart compatible with the SDK constraint in `erick_connect_app/pubspec.yaml` (`^3.9.2`).
- PostgreSQL with the PostGIS extension, or a Supabase PostgreSQL database with PostGIS enabled.
- Redis for driver availability and nearby-driver discovery.

Start the backend first:

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
# Set SUPABASE_DB_URL or DATABASE_URL, JWT_SECRET_KEY, and REDIS_URL in .env
alembic upgrade head
uvicorn app.main:app --reload
```

Then start Flutter from a second terminal:

```powershell
cd erick_connect_app
flutter pub get
flutter run
```

The backend exposes interactive API documentation at [`http://localhost:8000/docs`](http://localhost:8000/docs) and ReDoc at [`http://localhost:8000/redoc`](http://localhost:8000/redoc).

For an Android emulator, the client normally needs `BASE_URL=http://10.0.2.2:8000`; a physical device needs the development machine’s LAN address. Use an HTTPS base URL outside local development so the client derives `wss://` for live events.

## Engineering conventions

- Keep REST endpoint paths in `erick_connect_app/lib/config/api_endpoints.dart`.
- Keep ride transitions in the backend state machine; callers must not mutate ride status directly.
- Treat `ride_snapshot` and REST snapshots as recovery data after reconnects or app resume.
- Do not expose rider identity or contact details in nearby-driver discovery or unaccepted ride-request events.
- Do not commit `.env` files, JWT secrets, database credentials, or production URLs.

## Further reading

- Backend architecture, API surface, persistence, WebSocket protocol, and operations: [`backend/README.md`](backend/README.md)
- Flutter architecture, screens, services, WebSocket manager, location handling, and client configuration: [`erick_connect_app/README.md`](erick_connect_app/README.md)
