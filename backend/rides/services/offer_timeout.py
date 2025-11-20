from datetime import timedelta
from typing import Tuple

from django.db import close_old_connections
from django.utils import timezone

from rides.models import RideOffer
from rides.notifications import expire_offer_and_dispatch


def process_offer_timeouts(timeout_seconds: int = 10) -> Tuple[int, int]:
    """Expire stale offers and attempt to dispatch the next driver.

    Returns a tuple of (expired_count, dispatched_count).
    """

    cutoff = timezone.now() - timedelta(seconds=timeout_seconds)
    stale_offers = (
        RideOffer.objects.select_related("ride")
        .filter(status="pending", sent_at__isnull=False, sent_at__lt=cutoff)
        .order_by("sent_at")
    )

    expired_count = 0
    dispatched_count = 0

    for offer in stale_offers:
        expired_count += 1
        if expire_offer_and_dispatch(offer):
            dispatched_count += 1

    # Close stale DB connections for long-running workers
    close_old_connections()
    return expired_count, dispatched_count
