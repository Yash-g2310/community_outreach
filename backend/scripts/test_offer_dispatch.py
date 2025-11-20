import os
import sys
from pathlib import Path

import django

BASE_DIR = Path(__file__).resolve().parent.parent
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "app_backend.settings")
django.setup()

from django.utils import timezone  # noqa: E402
from rides.models import RideRequest, User, DriverProfile  # noqa: E402
from rides.notifications import build_offers_for_ride, dispatch_next_offer  # noqa: E402


def ensure_passenger(username: str) -> User:
    user, created = User.objects.get_or_create(
        username=username,
        defaults={
            "role": "user",
            "phone_number": "9000000000",
            "email": f"{username}@example.com",
        },
    )
    if created:
        user.set_password("demo1234")
        user.save()
    return user


def ensure_driver(username: str, vehicle_number: str, lat: float, lon: float) -> User:
    user, created = User.objects.get_or_create(
        username=username,
        defaults={
            "role": "driver",
            "phone_number": "9000011111",
            "email": f"{username}@example.com",
        },
    )
    if created:
        user.set_password("demo1234")
        user.save()

    DriverProfile.objects.update_or_create(
        user=user,
        defaults={
            "vehicle_number": vehicle_number,
            "status": "available",
            "current_latitude": lat,
            "current_longitude": lon,
            "last_location_update": timezone.now(),
        },
    )
    return user


def ensure_demo_ride(passenger: User) -> RideRequest:
    ride, _ = RideRequest.objects.get_or_create(
        passenger=passenger,
        status="pending",
        defaults={
            "pickup_latitude": 28.6139,
            "pickup_longitude": 77.2090,
            "pickup_address": "Connaught Place",
            "dropoff_address": "India Gate",
            "number_of_passengers": 2,
            "broadcast_radius": 1000,
        },
    )
    return ride


def main():
    passenger = ensure_passenger("offer_demo_passenger")
    driver_one = ensure_driver("offer_driver_one", "OF-1001", 28.6145, 77.2050)
    driver_two = ensure_driver("offer_driver_two", "OF-1002", 28.6100, 77.2100)
    driver_far = ensure_driver("offer_driver_far", "OF-1999", 28.5000, 77.5000)

    ride = ensure_demo_ride(passenger)
    ride.offers.all().delete()

    offers = build_offers_for_ride(ride)
    print(f"Queued {len(offers)} offers (should ignore far drivers).")
    for offer in offers:
        print(f"  order={offer.order} driver={offer.driver.username} status={offer.status}")

    dispatched = dispatch_next_offer(ride)
    sent_offer = ride.offers.filter(sent_at__isnull=False).order_by("sent_at").first()

    print("Dispatched first offer?", dispatched)
    if sent_offer:
        print(
            f"First driver notified: {sent_offer.driver.username} at {sent_offer.sent_at:%Y-%m-%d %H:%M:%S}"
        )
    else:
        print("No offer was sent. Check channel layer configuration.")


if __name__ == "__main__":
    main()
