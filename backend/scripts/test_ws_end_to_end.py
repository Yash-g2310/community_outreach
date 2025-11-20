"""End-to-end smoke test for driver-targeted WebSocket notifications.

Prerequisites:
1. `py manage.py runserver` must be running.
2. Install dependencies once: `py -m pip install requests websocket-client`.

The script will:
- Ensure a demo passenger and driver exist (auto-register if missing).
- Log them in via the REST API and configure the driver profile/location.
- Open the driver WebSocket connection (using the session cookie).
- Create a passenger ride request via REST and wait for the WS payload.
"""

from __future__ import annotations

import json
import os
import queue
import threading
import time
from typing import Dict

import requests
import websocket  # type: ignore

BASE_URL = os.environ.get("ERICK_BASE_URL", "http://127.0.0.1:8000")
API_ROOT = f"{BASE_URL}/api"
RIDES_API = f"{API_ROOT}/rides"
AUTH_API = f"{API_ROOT}/auth"

PASSENGER_CREDS = {
    "username": "ws_demo_passenger",
    "password": "demo1234",
    "phone_number": "9000000000",
}

DRIVER_CREDS = {
    "username": "ws_demo_driver",
    "password": "demo1234",
    "phone_number": "9000000001",
    "vehicle_number": "WS-1001",
}

PICKUP_COORDS = {
    "latitude": 28.6139,
    "longitude": 77.2090,
}


def _login_or_register(session: requests.Session, payload: Dict, role: str) -> Dict:
    login_resp = session.post(
        f"{AUTH_API}/login/",
        json={"username": payload["username"], "password": payload["password"]},
        timeout=10,
    )

    if login_resp.status_code != 200:
        register_body = {
            "username": payload["username"],
            "email": f"{payload['username']}@example.com",
            "password": payload["password"],
            "role": role,
            "phone_number": payload["phone_number"],
        }
        if role == "driver":
            register_body["vehicle_number"] = payload["vehicle_number"]
        reg_resp = session.post(f"{AUTH_API}/register/", json=register_body, timeout=10)
        reg_resp.raise_for_status()
        login_resp = session.post(
            f"{AUTH_API}/login/",
            json={"username": payload["username"], "password": payload["password"]},
            timeout=10,
        )

    login_resp.raise_for_status()
    data = login_resp.json()
    token = data["tokens"]["access"]
    session.headers.update({"Authorization": f"Bearer {token}"})
    return data["user"]


def _ensure_driver_profile(session: requests.Session) -> None:
    resp = session.post(
        f"{RIDES_API}/driver/profile/",
        json={"vehicle_number": DRIVER_CREDS["vehicle_number"]},
        timeout=10,
    )
    resp.raise_for_status()

    resp = session.post(
        f"{RIDES_API}/driver/location/",
        json={"latitude": PICKUP_COORDS["latitude"], "longitude": PICKUP_COORDS["longitude"]},
        timeout=10,
    )
    resp.raise_for_status()

    resp = session.patch(
        f"{RIDES_API}/driver/status/",
        json={"status": "available"},
        timeout=10,
    )
    resp.raise_for_status()


def _open_driver_socket(session: requests.Session, ready_evt: threading.Event, queue_out: queue.Queue) -> None:
    session_id = session.cookies.get("sessionid")
    if not session_id:
        raise RuntimeError("Driver session missing sessionid cookie; ensure login_view sets sessions.")

    ws_url = BASE_URL.replace("http", "ws") + "/ws/driver/rides/"

    def on_open(ws):  # type: ignore[no-untyped-def]
        print("[WS] Connected to driver channel")
        ready_evt.set()

    def on_message(ws, message):  # type: ignore[no-untyped-def]
        payload = json.loads(message)
        print(f"[WS] Received payload: {payload}")
        if payload.get("type") == "new_ride_request":
            queue_out.put(payload)
            ws.close()

    def on_error(ws, error):  # type: ignore[no-untyped-def]
        print(f"[WS] Error: {error}")
        ready_evt.set()

    def on_close(_ws, *_):  # type: ignore[no-untyped-def]
        print("[WS] Connection closed")

    headers = [f"Cookie: sessionid={session_id}"]
    ws_app = websocket.WebSocketApp(
        ws_url,
        header=headers,
        on_open=on_open,
        on_message=on_message,
        on_error=on_error,
        on_close=on_close,
    )

    ws_app.run_forever()


def _create_ride(passenger_session: requests.Session) -> Dict:
    body = {
        "pickup_latitude": PICKUP_COORDS["latitude"],
        "pickup_longitude": PICKUP_COORDS["longitude"],
        "pickup_address": "Connaught Place",
        "dropoff_address": "India Gate",
        "number_of_passengers": 2,
        "broadcast_radius": 800,
    }
    resp = passenger_session.post(f"{RIDES_API}/passenger/request/", json=body, timeout=10)
    resp.raise_for_status()
    data = resp.json()
    print(
        f"[HTTP] Passenger ride response: {data['message']} | candidates={data.get('driver_candidates')}"
    )
    return data


def main() -> None:
    passenger_session = requests.Session()
    driver_session = requests.Session()

    print("[HTTP] Logging in / registering demo accounts ...")
    passenger = _login_or_register(passenger_session, PASSENGER_CREDS, role="user")
    driver = _login_or_register(driver_session, DRIVER_CREDS, role="driver")
    _ensure_driver_profile(driver_session)
    print(f"[HTTP] Passenger #{passenger['id']} + Driver #{driver['id']} ready")

    ready_evt = threading.Event()
    message_queue: queue.Queue = queue.Queue()
    ws_thread = threading.Thread(
        target=_open_driver_socket,
        args=(driver_session, ready_evt, message_queue),
        daemon=True,
    )
    ws_thread.start()

    if not ready_evt.wait(timeout=5):
        raise TimeoutError("Driver WebSocket failed to connect within 5 seconds")

    ride_response = _create_ride(passenger_session)

    try:
        payload = message_queue.get(timeout=30)
        ride = payload.get("ride", {})
        print(
            "[RESULT] Driver received ride",
            ride.get("id"),
            "status=",
            ride.get("status"),
        )
    except queue.Empty:
        raise TimeoutError("Driver WebSocket did not receive a ride notification within 30 seconds")

    print("[DONE] End-to-end WebSocket check completed.")


if __name__ == "__main__":
    main()
