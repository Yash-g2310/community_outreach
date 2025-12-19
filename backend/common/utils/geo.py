"""
Geographic utility functions.

This module provides core geospatial calculations used throughout the application.
"""

from math import radians, cos, sin, asin, sqrt
from typing import Set


def calculate_distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """
    Calculate distance between two points in meters using Haversine formula.
    
    Args:
        lat1: Latitude of first point
        lon1: Longitude of first point
        lat2: Latitude of second point
        lon2: Longitude of second point
    
    Returns:
        Distance in meters
    """
    lat1, lon1, lat2, lon2 = map(radians, [float(lat1), float(lon1), float(lat2), float(lon2)])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = sin(dlat / 2) ** 2 + cos(lat1) * cos(lat2) * sin(dlon / 2) ** 2
    c = 2 * asin(sqrt(a))
    r = 6371000  # Earth's radius in meters
    return c * r


# Base32 alphabet for geohash
_BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz"


def encode_geohash(lat: float, lon: float, precision: int = 6) -> str:
    """
    Encode latitude/longitude to geohash string.
    
    Args:
        lat: Latitude (-90 to 90)
        lon: Longitude (-180 to 180)
        precision: Number of characters (1-12)
    
    Returns:
        Geohash string
    """
    lat_range = (-90.0, 90.0)
    lon_range = (-180.0, 180.0)
    
    geohash = []
    bits = [16, 8, 4, 2, 1]
    bit = 0
    ch = 0
    is_lon = True
    
    while len(geohash) < precision:
        if is_lon:
            mid = (lon_range[0] + lon_range[1]) / 2
            if lon >= mid:
                ch |= bits[bit]
                lon_range = (mid, lon_range[1])
            else:
                lon_range = (lon_range[0], mid)
        else:
            mid = (lat_range[0] + lat_range[1]) / 2
            if lat >= mid:
                ch |= bits[bit]
                lat_range = (mid, lat_range[1])
            else:
                lat_range = (lat_range[0], mid)
        
        is_lon = not is_lon
        
        if bit < 4:
            bit += 1
        else:
            geohash.append(_BASE32[ch])
            bit = 0
            ch = 0
    
    return "".join(geohash)


def get_covering_geohashes(lat: float, lon: float, radius_meters: float, precision: int = 6) -> Set[str]:
    """
    Get all geohash cells that cover the circular area around a point.
    
    Args:
        lat: Center latitude
        lon: Center longitude
        radius_meters: Search radius in meters
        precision: Geohash precision
    
    Returns:
        Set of geohash strings covering the area
    """
    import math
    
    # Calculate approximate degree offset for the radius
    lat_offset = radius_meters / 111000.0
    lon_offset = radius_meters / (111000.0 * abs(math.cos(math.radians(lat))))
    
    geohashes = set()
    
    # Sample points in a grid pattern
    steps = 3
    for lat_step in range(-steps, steps + 1):
        for lon_step in range(-steps, steps + 1):
            sample_lat = lat + (lat_step * lat_offset / steps)
            sample_lon = lon + (lon_step * lon_offset / steps)
            gh = encode_geohash(sample_lat, sample_lon, precision)
            geohashes.add(gh)
    
    return geohashes
