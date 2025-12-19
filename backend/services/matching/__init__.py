"""
Driver matching and offer dispatch service.

This module handles:
    - Building ordered driver offer queues for rides
    - Dispatching offers to drivers (daisy-chain pattern)
    - Expiring offers and moving to next driver
"""

from .offer_builder import build_offers_for_ride
from .offer_dispatch import dispatch_next_offer, expire_offer_and_dispatch

__all__ = [
    "build_offers_for_ride",
    "dispatch_next_offer",
    "expire_offer_and_dispatch",
]
