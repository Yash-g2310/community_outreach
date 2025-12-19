"""Utility functions for the realtime app.

This module re-exports from common.utils for backward compatibility.
New code should import directly from common.utils.
"""

from common.utils import calculate_distance

__all__ = ["calculate_distance"]
