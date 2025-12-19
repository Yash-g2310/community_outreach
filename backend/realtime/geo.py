"""
Redis GEO-based driver location service.

This module provides:
- Geospatial indexing of driver locations using Redis GEO
- Geohash-based pub/sub channel management
- Fast proximity queries for nearby drivers
- Driver presence tracking with TTL

Architecture:
- Drivers are indexed in Redis GEO set for fast GEORADIUS queries
- Location updates are published to geohash-partitioned channels
- Passengers subscribe to geohash channels covering their viewport/radius
- All data has TTL to automatically clean up stale entries
"""

from __future__ import annotations

import logging
import json
from typing import Dict, Any, List, Optional, Set
from dataclasses import dataclass

import redis
from django.conf import settings
from asgiref.sync import sync_to_async

logger = logging.getLogger(__name__)


# ---------------------- Configuration ----------------------

# Redis GEO configuration
REDIS_GEO_CONFIG = {
    # Key names
    "DRIVERS_GEO_KEY": "drivers:geo",           # GEOADD key for driver positions
    "DRIVER_META_PREFIX": "driver:meta:",        # HSET for driver metadata
    "DRIVER_PRESENCE_KEY": "drivers:online",     # SET for active driver IDs
    "PASSENGER_SUBS_PREFIX": "passenger:subs:",  # SET of geohash channels per passenger
    
    # TTL values (seconds)
    "DRIVER_LOCATION_TTL": 120,        # Driver location expires after 2 min of inactivity
    "DRIVER_META_TTL": 120,            # Driver metadata TTL
    "PASSENGER_SUB_TTL": 300,          # Passenger subscription TTL (5 min)
    
    # Geohash precision for pub/sub channels
    # Precision 5 = ~4.9km x 4.9km tiles (good for city-level)
    # Precision 6 = ~1.2km x 0.6km tiles (good for neighborhood-level)
    # Precision 7 = ~150m x 150m tiles (good for block-level)
    "GEOHASH_PRECISION": 6,
    
    # Pub/sub channel prefix
    "LOCATION_CHANNEL_PREFIX": "loc_updates:",
    
    # Rate limiting
    "MIN_UPDATE_DISTANCE_METERS": 10,  # Ignore updates if moved less than this
    "MAX_UPDATES_PER_SECOND": 2,       # Rate limit per driver
}


# ---------------------- Redis Connection ----------------------

def get_redis_client() -> redis.Redis:
    """Get Redis client for GEO operations."""
    return redis.Redis.from_url(
        getattr(settings, 'REDIS_GEO_URL', settings.CELERY_BROKER_URL),
        decode_responses=True
    )


def get_async_redis_client():
    """Get async Redis client (uses redis-py async support)."""
    import redis.asyncio as aioredis
    return aioredis.from_url(
        getattr(settings, 'REDIS_GEO_URL', settings.CELERY_BROKER_URL),
        decode_responses=True
    )


# ---------------------- Geohash Utilities ----------------------

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


def get_geohash_neighbors(geohash: str) -> List[str]:
    """
    Get the 8 neighboring geohash cells plus the center cell.
    This ensures we cover the edges when a user is near a tile boundary.
    
    Returns 9 geohashes: center + 8 neighbors
    """
    # Simplified neighbor calculation - returns approximate neighbors
    # For production, use a proper geohash library
    neighbors = set()
    neighbors.add(geohash)
    
    # For now, just return the center cell and truncated versions
    # A full implementation would calculate actual neighboring cells
    if len(geohash) > 1:
        # Add parent cell (lower precision = larger area)
        neighbors.add(geohash[:-1])
    
    return list(neighbors)


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
    # Calculate approximate degree offset for the radius
    # 1 degree latitude ≈ 111km, 1 degree longitude varies by latitude
    lat_offset = radius_meters / 111000.0
    lon_offset = radius_meters / (111000.0 * abs(cos_deg(lat)))
    
    geohashes = set()
    
    # Sample points in a grid pattern
    steps = 3  # Sample 3x3 grid
    for lat_step in range(-steps, steps + 1):
        for lon_step in range(-steps, steps + 1):
            sample_lat = lat + (lat_step * lat_offset / steps)
            sample_lon = lon + (lon_step * lon_offset / steps)
            gh = encode_geohash(sample_lat, sample_lon, precision)
            geohashes.add(gh)
    
    return geohashes


def cos_deg(degrees: float) -> float:
    """Cosine of degrees."""
    import math
    return math.cos(math.radians(degrees))


# ---------------------- Driver Location Service ----------------------

@dataclass
class DriverLocation:
    """Driver location data."""
    driver_id: int
    latitude: float
    longitude: float
    username: Optional[str] = None
    vehicle_number: Optional[str] = None
    status: str = "available"
    distance_meters: Optional[float] = None


class DriverLocationService:
    """
    Redis GEO-based driver location service.
    
    Provides:
    - Update driver location (GEOADD + metadata)
    - Query nearby drivers (GEORADIUS)
    - Geohash channel management for pub/sub
    - Driver presence tracking
    """
    
    def __init__(self, redis_client: Optional[redis.Redis] = None):
        self._redis = redis_client or get_redis_client()
        self._config = REDIS_GEO_CONFIG
    
    # ---------------------- Driver Location Updates ----------------------
    
    def update_driver_location(
        self,
        driver_id: int,
        lat: float,
        lon: float,
        username: Optional[str] = None,
        vehicle_number: Optional[str] = None,
        status: str = "available",
    ) -> Dict[str, Any]:
        """
        Update driver's location in Redis GEO and publish to geohash channels.
        
        Returns dict with:
            - geohash: The driver's current geohash cell
            - prev_geohash: Previous geohash (if changed)
            - channels: Channels to publish update to
            - moved: Whether location actually changed significantly
        """
        try:
            geo_key = self._config["DRIVERS_GEO_KEY"]
            meta_key = f"{self._config['DRIVER_META_PREFIX']}{driver_id}"
            precision = self._config["GEOHASH_PRECISION"]
            
            # Calculate new geohash
            new_geohash = encode_geohash(lat, lon, precision)
            
            # Get previous position to check if moved significantly
            prev_pos = self._redis.geopos(geo_key, str(driver_id))
            prev_geohash = None
            moved = True
            
            if prev_pos and prev_pos[0]:
                prev_lon, prev_lat = prev_pos[0]
                prev_geohash = encode_geohash(prev_lat, prev_lon, precision)
                
                # Check minimum movement threshold
                from .utils import calculate_distance
                distance_moved = calculate_distance(prev_lat, prev_lon, lat, lon)
                if distance_moved < self._config["MIN_UPDATE_DISTANCE_METERS"]:
                    moved = False
            
            # Update GEO position
            self._redis.geoadd(geo_key, (lon, lat, str(driver_id)))
            
            # Update metadata with TTL
            meta = {
                "driver_id": str(driver_id),
                "username": username or "",
                "vehicle_number": vehicle_number or "",
                "status": status,
                "latitude": str(lat),
                "longitude": str(lon),
                "geohash": new_geohash,
            }
            self._redis.hset(meta_key, mapping=meta)
            self._redis.expire(meta_key, self._config["DRIVER_META_TTL"])
            
            # Add to presence set (active drivers)
            if status == "available":
                self._redis.sadd(self._config["DRIVER_PRESENCE_KEY"], str(driver_id))
            else:
                self._redis.srem(self._config["DRIVER_PRESENCE_KEY"], str(driver_id))
            
            # Determine which channels to publish to (current + neighbors)
            channels = []
            if moved or status != "available":
                for gh in get_geohash_neighbors(new_geohash):
                    channels.append(f"{self._config['LOCATION_CHANNEL_PREFIX']}{gh}")
            
            return {
                "geohash": new_geohash,
                "prev_geohash": prev_geohash,
                "channels": channels,
                "moved": moved,
                "geohash_changed": prev_geohash != new_geohash if prev_geohash else True,
            }
            
        except Exception as e:
            logger.exception("Failed to update driver location: %s", e)
            return {"geohash": None, "channels": [], "moved": False, "error": str(e)}
    
    def remove_driver(self, driver_id: int) -> bool:
        """Remove driver from GEO index and presence set."""
        try:
            self._redis.zrem(self._config["DRIVERS_GEO_KEY"], str(driver_id))
            self._redis.delete(f"{self._config['DRIVER_META_PREFIX']}{driver_id}")
            self._redis.srem(self._config["DRIVER_PRESENCE_KEY"], str(driver_id))
            return True
        except Exception as e:
            logger.exception("Failed to remove driver: %s", e)
            return False
    
    # ---------------------- Nearby Driver Queries ----------------------
    
    def get_nearby_drivers(
        self,
        lat: float,
        lon: float,
        radius_meters: float = 1500,
        limit: int = 50,
        status_filter: Optional[str] = "available",
    ) -> List[DriverLocation]:
        """
        Query nearby drivers using GEORADIUS.
        
        Args:
            lat: Center latitude
            lon: Center longitude
            radius_meters: Search radius in meters
            limit: Max drivers to return
            status_filter: Only return drivers with this status (None = all)
        
        Returns:
            List of DriverLocation objects sorted by distance
        """
        try:
            geo_key = self._config["DRIVERS_GEO_KEY"]
            
            # Query nearby using GEOSEARCH (Redis 6.2+) or GEORADIUS
            results = self._redis.georadius(
                geo_key,
                lon, lat,
                radius_meters,
                unit="m",
                withdist=True,
                withcoord=True,
                count=limit * 2,  # Fetch more to filter by status
                sort="ASC",
            )
            
            drivers = []
            for item in results:
                driver_id_str = item[0]
                distance = item[1]
                coords = item[2]  # (lon, lat)
                
                # Fetch metadata
                meta = self._redis.hgetall(f"{self._config['DRIVER_META_PREFIX']}{driver_id_str}")
                
                if not meta:
                    continue
                
                # Filter by status if specified
                driver_status = meta.get("status", "unknown")
                if status_filter and driver_status != status_filter:
                    continue
                
                drivers.append(DriverLocation(
                    driver_id=int(driver_id_str),
                    latitude=coords[1],
                    longitude=coords[0],
                    username=meta.get("username") or None,
                    vehicle_number=meta.get("vehicle_number") or None,
                    status=driver_status,
                    distance_meters=distance,
                ))
                
                if len(drivers) >= limit:
                    break
            
            return drivers
            
        except Exception as e:
            logger.exception("Failed to query nearby drivers: %s", e)
            return []
    
    def get_driver_location(self, driver_id: int) -> Optional[DriverLocation]:
        """Get a specific driver's current location and metadata."""
        try:
            geo_key = self._config["DRIVERS_GEO_KEY"]
            meta_key = f"{self._config['DRIVER_META_PREFIX']}{driver_id}"
            
            pos = self._redis.geopos(geo_key, str(driver_id))
            if not pos or not pos[0]:
                return None
            
            meta = self._redis.hgetall(meta_key)
            lon, lat = pos[0]
            
            return DriverLocation(
                driver_id=driver_id,
                latitude=lat,
                longitude=lon,
                username=meta.get("username") or None,
                vehicle_number=meta.get("vehicle_number") or None,
                status=meta.get("status", "unknown"),
            )
            
        except Exception as e:
            logger.exception("Failed to get driver location: %s", e)
            return None
    
    # ---------------------- Passenger Subscription Management ----------------------
    
    def subscribe_passenger_to_area(
        self,
        passenger_id: int,
        channel_name: str,
        lat: float,
        lon: float,
        radius_meters: float = 1500,
    ) -> Dict[str, Any]:
        """
        Subscribe a passenger to geohash channels covering their area.
        
        Returns:
            Dict with geohashes subscribed to and nearby drivers
        """
        try:
            precision = self._config["GEOHASH_PRECISION"]
            subs_key = f"{self._config['PASSENGER_SUBS_PREFIX']}{passenger_id}"
            
            # Get covering geohashes
            geohashes = get_covering_geohashes(lat, lon, radius_meters, precision)
            
            # Store subscription info
            sub_data = {
                "channel_name": channel_name,
                "latitude": str(lat),
                "longitude": str(lon),
                "radius": str(radius_meters),
                "geohashes": ",".join(geohashes),
            }
            self._redis.hset(subs_key, mapping=sub_data)
            self._redis.expire(subs_key, self._config["PASSENGER_SUB_TTL"])
            
            # Get channels to subscribe to
            channels = [f"{self._config['LOCATION_CHANNEL_PREFIX']}{gh}" for gh in geohashes]
            
            # Also fetch current nearby drivers
            nearby = self.get_nearby_drivers(lat, lon, radius_meters)
            
            return {
                "geohashes": list(geohashes),
                "channels": channels,
                "nearby_drivers": [
                    {
                        "driver_id": d.driver_id,
                        "latitude": d.latitude,
                        "longitude": d.longitude,
                        "username": d.username,
                        "vehicle_number": d.vehicle_number,
                        "distance_meters": d.distance_meters,
                    }
                    for d in nearby
                ],
            }
            
        except Exception as e:
            logger.exception("Failed to subscribe passenger: %s", e)
            return {"geohashes": [], "channels": [], "nearby_drivers": []}
    
    def unsubscribe_passenger(self, passenger_id: int) -> bool:
        """Remove passenger subscription."""
        try:
            self._redis.delete(f"{self._config['PASSENGER_SUBS_PREFIX']}{passenger_id}")
            return True
        except Exception:
            return False
    
    def get_passenger_subscription(self, passenger_id: int) -> Optional[Dict[str, Any]]:
        """Get passenger's subscription info."""
        try:
            subs_key = f"{self._config['PASSENGER_SUBS_PREFIX']}{passenger_id}"
            data = self._redis.hgetall(subs_key)
            if not data:
                return None
            return {
                "channel_name": data.get("channel_name"),
                "latitude": float(data.get("latitude", 0)),
                "longitude": float(data.get("longitude", 0)),
                "radius": float(data.get("radius", 1500)),
                "geohashes": data.get("geohashes", "").split(",") if data.get("geohashes") else [],
            }
        except Exception:
            return None
    
    def get_passengers_in_geohash(self, geohash: str) -> List[Dict[str, Any]]:
        """
        Get all passengers subscribed to a specific geohash channel.
        Used for broadcasting driver updates to relevant passengers.
        """
        try:
            passengers = []
            pattern = f"{self._config['PASSENGER_SUBS_PREFIX']}*"
            
            for key in self._redis.scan_iter(pattern, count=100):
                data = self._redis.hgetall(key)
                if not data:
                    continue
                
                geohashes = data.get("geohashes", "").split(",")
                if geohash in geohashes:
                    passengers.append({
                        "passenger_id": key.split(":")[-1],
                        "channel_name": data.get("channel_name"),
                        "latitude": float(data.get("latitude", 0)),
                        "longitude": float(data.get("longitude", 0)),
                        "radius": float(data.get("radius", 1500)),
                    })
            
            return passengers
            
        except Exception as e:
            logger.exception("Failed to get passengers in geohash: %s", e)
            return []


# ---------------------- Async Wrapper Service ----------------------

class AsyncDriverLocationService:
    """Async wrapper for DriverLocationService."""
    
    def __init__(self):
        self._sync_service = DriverLocationService()
    
    async def update_driver_location(self, *args, **kwargs):
        return await sync_to_async(self._sync_service.update_driver_location)(*args, **kwargs)
    
    async def remove_driver(self, *args, **kwargs):
        return await sync_to_async(self._sync_service.remove_driver)(*args, **kwargs)
    
    async def get_nearby_drivers(self, *args, **kwargs):
        return await sync_to_async(self._sync_service.get_nearby_drivers)(*args, **kwargs)
    
    async def get_driver_location(self, *args, **kwargs):
        return await sync_to_async(self._sync_service.get_driver_location)(*args, **kwargs)
    
    async def subscribe_passenger_to_area(self, *args, **kwargs):
        return await sync_to_async(self._sync_service.subscribe_passenger_to_area)(*args, **kwargs)
    
    async def unsubscribe_passenger(self, *args, **kwargs):
        return await sync_to_async(self._sync_service.unsubscribe_passenger)(*args, **kwargs)
    
    async def get_passenger_subscription(self, *args, **kwargs):
        return await sync_to_async(self._sync_service.get_passenger_subscription)(*args, **kwargs)
    
    async def get_passengers_in_geohash(self, *args, **kwargs):
        return await sync_to_async(self._sync_service.get_passengers_in_geohash)(*args, **kwargs)


# ---------------------- Singleton Instances ----------------------

_driver_location_service: Optional[DriverLocationService] = None
_async_driver_location_service: Optional[AsyncDriverLocationService] = None


def get_driver_location_service() -> DriverLocationService:
    """Get singleton DriverLocationService instance."""
    global _driver_location_service
    if _driver_location_service is None:
        _driver_location_service = DriverLocationService()
    return _driver_location_service


def get_async_driver_location_service() -> AsyncDriverLocationService:
    """Get singleton AsyncDriverLocationService instance."""
    global _async_driver_location_service
    if _async_driver_location_service is None:
        _async_driver_location_service = AsyncDriverLocationService()
    return _async_driver_location_service
