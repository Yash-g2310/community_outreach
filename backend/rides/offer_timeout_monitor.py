"""It runs a background thread that keeps checking for ride offers that have timed out"""

import logging
import os
import threading
from typing import Optional

from django.conf import settings

from .services.offer_timeout import process_offer_timeouts

logger = logging.getLogger(__name__)

_monitor_instance: Optional["OfferTimeoutMonitor"] = None


class OfferTimeoutMonitor:
    def __init__(self, timeout_seconds: int, interval_seconds: int):
        self.timeout_seconds = timeout_seconds
        self.interval_seconds = interval_seconds
        self._stop_event = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        if not self._thread.is_alive():
            logger.info(
                "Starting ride offer timeout monitor (timeout=%ss interval=%ss)",
                self.timeout_seconds,
                self.interval_seconds,
            )
            self._thread.start()

    def stop(self):
        self._stop_event.set()

    def _run(self):
        while not self._stop_event.wait(self.interval_seconds):
            try:
                expired, dispatched = process_offer_timeouts(self.timeout_seconds)
                if expired or dispatched:
                    logger.info(
                        "Offer monitor expired %s, dispatched %s",
                        expired,
                        dispatched,
                    )
            except Exception:  # pragma: no cover - best effort logging
                logger.exception("Offer timeout monitor encountered an error")


def start_offer_timeout_monitor():
    global _monitor_instance

    if getattr(settings, "ENABLE_OFFER_TIMEOUT_MONITOR", True) is False:
        return

    # Avoid double-start in Django's autoreload parent process
    run_main = os.environ.get("RUN_MAIN")
    if run_main not in (None, "true"):
        return

    if _monitor_instance is None:
        timeout_seconds = getattr(settings, "RIDE_OFFER_TIMEOUT_SECONDS", 10)
        interval_seconds = getattr(settings, "RIDE_OFFER_MONITOR_INTERVAL", 5)
        _monitor_instance = OfferTimeoutMonitor(timeout_seconds, interval_seconds)
        _monitor_instance.start()
