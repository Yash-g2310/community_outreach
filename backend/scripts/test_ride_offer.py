"""Minimal standalone script to sanity-check the RideOffer model.

Run from the backend/ directory:
    python scripts/test_ride_offer.py

It will:
1. Ensure demo passenger/driver users exist.
2. Create a demo RideRequest (if missing).
3. Create or update a RideOffer row and print the current ledger.
"""

import os
import sys
from datetime import datetime
from pathlib import Path

import django

# Ensure the Django project root (backend/) is on sys.path so imports work
BASE_DIR = Path(__file__).resolve().parent.parent
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

# Point Django to the project settings and bootstrap ORM
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "app_backend.settings")
django.setup()

from django.utils import timezone  # noqa: E402
from rides.models import DriverProfile, RideOffer, RideRequest, User  # noqa: E402


def get_or_create_user(username: str, role: str, **extra_fields) -> User:
    user, created = User.objects.get_or_create(
        username=username,
        defaults={
            "role": role,
            "phone_number": extra_fields.get("phone_number", "0000000000"),
            "email": extra_fields.get("email", f"{username}@example.com"),
        },
    )
    if created:
        user.set_password("demo1234")
        user.save()
    return user


def ensure_driver_profile(driver: User) -> None:
    DriverProfile.objects.get_or_create(
        user=driver,
        defaults={
            "vehicle_number": f"DEMO-{driver.id:04d}",
            "status": "available",
            "current_latitude": 28.6139,
            "current_longitude": 77.2090,
            "last_location_update": timezone.now(),
        },
    )


def ensure_ride(passenger: User) -> RideRequest:
    ride, _ = RideRequest.objects.get_or_create(
        passenger=passenger,
        status="pending",
        pickup_latitude=28.7041,
        pickup_longitude=77.1025,
        defaults={
            "pickup_address": "Connaught Place",
            "dropoff_address": "India Gate",
            "number_of_passengers": 2,
            "broadcast_radius": 800,
        },
    )
    return ride


def create_offer(ride: RideRequest, driver: User, order: int = 0) -> RideOffer:
    offer, created = RideOffer.objects.get_or_create(
        ride=ride,
        driver=driver,
        defaults={
            "order": order,
            "status": "pending",
            "sent_at": timezone.now(),
        },
    )
    if not created:
        # keep the ledger fresh for repeated runs
        offer.order = order
        offer.sent_at = timezone.now()
        offer.status = "pending"
        offer.responded_at = None
        offer.save()
    return offer


def print_offers(ride: RideRequest) -> None:
    print(f"\nRide #{ride.id} currently has the following offers:")
    for offer in ride.offers.select_related("driver").order_by("order"):
        print(
            f"  order={offer.order} driver={offer.driver.username} status={offer.status} "
            f"sent_at={offer.sent_at:%Y-%m-%d %H:%M:%S}" +
            (f" responded_at={offer.responded_at:%Y-%m-%d %H:%M:%S}" if offer.responded_at else ""),
        )


def main() -> None:
    passenger = get_or_create_user("demo_passenger", "user")
    driver = get_or_create_user("demo_driver", "driver")
    ensure_driver_profile(driver)

    ride = ensure_ride(passenger)
    offer = create_offer(ride, driver, order=0)

    print(f"Created/updated RideOffer id={offer.id} for ride #{ride.id} -> driver {driver.username}")
    print_offers(ride)


if __name__ == "__main__":
    main()
