# E-Rick Connect backend

The active backend is FastAPI in `fastapi_app`. The Django folders remain only
as legacy code while the migration is completed; do not add new API or socket
features there.

## Local setup

Create `backend/.env` from `.env.example`, then set `SUPABASE_DB_URL` (or
`DATABASE_URL`) and a private `JWT_SECRET_KEY` of at least 32 random
characters. Apply the schema and start FastAPI from `backend/`:

```powershell
alembic upgrade head
uvicorn fastapi_app.main:app --reload
```

## Authentication

FastAPI exposes:

- `POST /api/v1/auth/register`
- `POST /api/v1/auth/login`
- `POST /api/v1/auth/refresh`
- `POST /api/v1/auth/logout`
- `GET /api/v1/auth/me`
- `GET /api/v1/rider/nearby-drivers?latitude=<lat>&longitude=<lon>`
- `POST /api/v1/rider/request`
- `GET /api/v1/driver/ride-requests/pending`
- `POST /api/v1/driver/ride-requests/{ride_id}/accept`

Protected REST endpoints use `Authorization: Bearer <access-token>`. The live
ride socket is `GET ws(s)://<host>/ws/app/?token=<access-token>` and rejects
unauthenticated or revoked sessions before accepting the connection. Always
use `wss://` outside local development so the token stays encrypted in transit.

The service intentionally handles account and ride-connection concerns only:
it contains no payments, price estimation, ratings, promotions, or add-on
services.

## Nearby drivers

Authenticated riders can query the live available-driver index with
`GET /api/v1/rider/nearby-drivers`. The request accepts `latitude`,
`longitude`, optional `radius_meters` (default `1500`, maximum `10000`), and
optional `limit` (default `20`, maximum `50`). Results are ordered nearest
first and expose only `driver_id`, `latitude`, and `longitude`; no name,
phone, vehicle, account, pricing, or rating data is disclosed.

`POST /api/v1/rider/request` creates one active request for the authenticated
rider and broadcasts it to every currently available driver within the
server-configured `RIDE_REQUEST_BROADCAST_RADIUS_METERS` distance (default
`1000` metres). It accepts `pickup_latitude`, `pickup_longitude`, optional
pickup/drop-off addresses, and `number_of_passengers` (default `1`). The
stored recipient list makes the request durable even when a driver is
temporarily disconnected.

New ride requests enter the `searching` state while matching. If no available
drivers are found, they transition immediately to `expired`; otherwise they
remain `searching` until a driver accepts or the rider cancels.

`RIDE_REQUEST_SEARCH_TIMEOUT_SECONDS` is server-controlled (default `60`).
When it expires without an acceptance, the ride and all pending recipient rows
become `expired`; the rider receives `ride_request_expired` and recipient
drivers receive `ride_request_closed`.

## Driver request delivery

Each authenticated WebSocket is registered under its user ID only while it is
connected. After a ride request and its pending recipient rows commit, the API
sends every intended connected driver this ride-request event:

```json
{
  "type": "ride_request",
  "ride_id": "ride UUID",
  "pickup": {"lat": 28.6139, "lng": 77.2090},
  "pickup_address": "Pickup address",
  "dropoff_address": "Drop-off address",
  "passenger_count": 1
}
```

Drivers can recover requests sent while they were disconnected with
`GET /api/v1/driver/ride-requests/pending`. It returns only pending
`searching` rides assigned to the authenticated driver, including pickup
location/address, drop-off address, and passenger count. Rider identity and
contact details are never included.

## Accepting a ride

Only a driver with a pending recipient row can call
`POST /api/v1/driver/ride-requests/{ride_id}/accept`. The API locks the driver
profile, ride, and recipient row so only the first driver can win. It changes
the ride to `accepted`, changes the winner to `accepted`, expires every other
pending recipient, marks the winning driver `busy`, and removes that driver
from nearby discovery. Rider and winning driver receive `ride_accepted` with
the active channel name `ride:{ride_id}`; other drivers receive
`ride_request_closed`.
