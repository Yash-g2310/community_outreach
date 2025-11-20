import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List

import django

BASE_DIR = Path(__file__).resolve().parent.parent
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "app_backend.settings")
django.setup()

from django.contrib.auth import get_user_model
from rides.models import DriverProfile
from rides.consumers import RideNotificationConsumer

User = get_user_model()


def ensure_driver(username: str, vehicle_suffix: str) -> Any:
    """Create or update a driver profile we can reuse for websocket tests."""
    driver_defaults = {
        "role": "driver",
        "phone_number": f"90000{vehicle_suffix}",
        "email": f"{username}@example.com",
    }

    driver, created = User.objects.get_or_create(username=username, defaults=driver_defaults)

    changed = False
    for field, value in driver_defaults.items():
        if getattr(driver, field) != value:
            setattr(driver, field, value)
            changed = True

    if changed:
        driver.save(update_fields=["role", "phone_number", "email"])

    DriverProfile.objects.update_or_create(
        user=driver,
        defaults={
            "vehicle_number": f"WB-{vehicle_suffix}",
            "status": "available",
        },
    )

    return driver


async def collect_messages(driver: Any, handler_name: str, event_payload: dict) -> List[Dict]:
    """Invoke the consumer handler and capture outgoing websocket messages."""
    consumer = RideNotificationConsumer()
    consumer.scope = {"user": driver}
    consumer.user = driver

    messages: List[Dict] = []

    async def fake_send(*, text_data=None, bytes_data=None):
        payload = text_data or bytes_data
        if isinstance(payload, bytes):
            payload = payload.decode("utf-8")
        messages.append(json.loads(payload))

    consumer.send = fake_send  # type: ignore[assignment]

    handler = getattr(consumer, handler_name)
    await handler(event_payload)
    return messages


async def run_checks(driver_a, driver_b):
    ride_stub = {
        "id": 9999,
        "pickup_address": "Demo Pickup Point",
        "dropoff_address": "Demo Dropoff Spot",
        "number_of_passengers": 2,
    }

    scenarios = {
        "targeted_new_request": await collect_messages(
            driver_a,
            "new_ride_request",
            {"ride_data": ride_stub, "driver_id": driver_a.id},
        ),
        "broadcast_new_request": await collect_messages(
            driver_a,
            "new_ride_request",
            {"ride_data": ride_stub, "driver_id": None},
        ),
        "skipped_new_request": await collect_messages(
            driver_a,
            "new_ride_request",
            {"ride_data": ride_stub, "driver_id": driver_b.id},
        ),
        "targeted_ride_cancelled": await collect_messages(
            driver_a,
            "ride_cancelled",
            {"ride_id": ride_stub["id"], "driver_id": driver_a.id},
        ),
        "skipped_ride_cancelled": await collect_messages(
            driver_a,
            "ride_cancelled",
            {"ride_id": ride_stub["id"], "driver_id": driver_b.id},
        ),
        "targeted_ride_accepted": await collect_messages(
            driver_a,
            "ride_accepted",
            {"ride_id": ride_stub["id"], "driver_id": driver_a.id},
        ),
        "skipped_ride_accepted": await collect_messages(
            driver_a,
            "ride_accepted",
            {"ride_id": ride_stub["id"], "driver_id": driver_b.id},
        ),
    }

    assert len(scenarios["targeted_new_request"]) == 1, "Targeted ride requests should deliver exactly one message."
    assert len(scenarios["broadcast_new_request"]) == 1, "Broadcast ride requests should deliver to all drivers."
    assert len(scenarios["skipped_new_request"]) == 0, "Mismatched ride request should be ignored."
    assert len(scenarios["targeted_ride_cancelled"]) == 1, "Targeted cancellations should deliver exactly one message."
    assert len(scenarios["skipped_ride_cancelled"]) == 0, "Mismatched cancellations should be ignored."
    assert len(scenarios["targeted_ride_accepted"]) == 1, "Targeted acceptances should deliver exactly one message."
    assert len(scenarios["skipped_ride_accepted"]) == 0, "Mismatched acceptances should be ignored."

    print("Driver-targeted notification handlers behaved as expected. Sample payloads:")
    for label, messages in scenarios.items():
        example = messages[0] if messages else None
        print(f"  - {label}: delivered {len(messages)} message(s){f' -> {example}' if example else ''}")


if __name__ == "__main__":
    driver_primary = ensure_driver("ws_driver_primary", "7101")
    driver_secondary = ensure_driver("ws_driver_secondary", "7102")
    asyncio.run(run_checks(driver_primary, driver_secondary))
