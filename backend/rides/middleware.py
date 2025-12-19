"""
DEPRECATED: This module is kept for backward compatibility.
Use realtime.middleware instead.
"""

from realtime.middleware import JWTOrCookieAuthMiddleware

__all__ = ["JWTOrCookieAuthMiddleware"]

