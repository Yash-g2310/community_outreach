"""
Geohash-based broadcast service for driver location updates.

This module provides efficient pub/sub broadcasting partitioned by geography.
Instead of broadcasting to all passengers, updates are sent only to passengers
subscribed to the relevant geohash tiles.

Architecture:
1. Driver sends location update → update Redis GEO + get affected geohashes
2. Lookup all passengers subscribed to those geohashes
3. For each passenger within actual radius, send WebSocket message
4. Rate limiting and deduplication at multiple layers
"""

from __future__ import annotations

import logging
import time
from typing import Dict, Any, List, Optional

from channels.layers import get_channel_layer
from asgiref.sync import async_to_sync

from .geo import (
    get_driver_location_service,
    get_async_driver_location_service,
    encode_geohash,
    get_geohash_neighbors,
    REDIS_GEO_CONFIG,
)
from .utils import calculate_distance

logger = logging.getLogger(__name__)


# Rate limiting cache (in-memory for now, could use Redis)
_last_broadcast_times: Dict[int, float] = {}


def _should_broadcast(driver_id: int, min_interval: float = 0.5) -> bool:
    """Check if enough time has passed since last broadcast for this driver."""
    now = time.time()
    last_time = _last_broadcast_times.get(driver_id, 0)
    if now - last_time < min_interval:
        return False
    _last_broadcast_times[driver_id] = now
    return True


# ---------------------- Sync Broadcast Functions ----------------------

def broadcast_driver_location(
    driver_id: int,
    lat: float,
    lon: float,
    username: Optional[str] = None,
    vehicle_number: Optional[str] = None,
    status: str = "available",
    force: bool = False,
) -> Dict[str, Any]:
    """
    Update driver location in Redis GEO and broadcast to nearby passengers.
    
    This is the main entry point for driver location updates.
    
    Args:
        driver_id: Driver's user ID
        lat: Latitude
        lon: Longitude
        username: Driver's display name
        vehicle_number: Vehicle registration number
        status: Driver status (available/busy/offline)
        force: Force broadcast even if rate limited
    
    Returns:
        Dict with broadcast stats
    """
    try:
        # Rate limiting check
        if not force and not _should_broadcast(driver_id):
            return {"broadcasted": False, "reason": "rate_limited"}
        
        service = get_driver_location_service()
        
        # Update location in Redis GEO
        result = service.update_driver_location(
            driver_id=driver_id,
            lat=lat,
            lon=lon,
            username=username,
            vehicle_number=vehicle_number,
            status=status,
        )
        
        if not result.get("moved") and not force:
            return {"broadcasted": False, "reason": "not_moved", **result}
        
        # Get channel layer for WebSocket messaging
        channel_layer = get_channel_layer()
        if not channel_layer:
            return {"broadcasted": False, "reason": "no_channel_layer", **result}
        
        # Build the location update payload
        payload = {
            "type": "driver_location_updated",
            "driver_id": driver_id,
            "latitude": lat,
            "longitude": lon,
            "username": username,
            "vehicle_number": vehicle_number,
            "status": status,
            "geohash": result.get("geohash"),
        }
        
        # Get passengers to notify
        passengers_notified = 0
        geohash = result.get("geohash")
        
        if geohash:
            # Get all neighboring geohashes to ensure we notify edge cases
            geohashes_to_check = get_geohash_neighbors(geohash)
            
            for gh in geohashes_to_check:
                passengers = service.get_passengers_in_geohash(gh)
                
                for passenger in passengers:
                    try:
                        p_lat = passenger.get("latitude", 0)
                        p_lon = passenger.get("longitude", 0)
                        p_radius = passenger.get("radius", 1500)
                        channel_name = passenger.get("channel_name")
                        
                        if not channel_name:
                            continue
                        
                        # Check actual distance (geohash is approximate)
                        distance = calculate_distance(p_lat, p_lon, lat, lon)
                        if distance > p_radius:
                            continue
                        
                        # Send to passenger's WebSocket channel
                        async_to_sync(channel_layer.send)(channel_name, payload)
                        passengers_notified += 1
                        
                    except Exception as e:
                        logger.warning("Failed to notify passenger: %s", e)
        
        return {
            "broadcasted": True,
            "passengers_notified": passengers_notified,
            "geohash": geohash,
            **result,
        }
        
    except Exception as e:
        logger.exception("broadcast_driver_location failed: %s", e)
        return {"broadcasted": False, "error": str(e)}


def broadcast_driver_status(
    driver_id: int,
    status: str,
    lat: Optional[float] = None,
    lon: Optional[float] = None,
    username: Optional[str] = None,
    vehicle_number: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Broadcast driver status change (available/busy/offline).
    
    If lat/lon not provided, uses last known location from Redis.
    """
    try:
        service = get_driver_location_service()
        
        # Get current location if not provided
        if lat is None or lon is None:
            driver = service.get_driver_location(driver_id)
            if driver:
                lat = driver.latitude
                lon = driver.longitude
                username = username or driver.username
                vehicle_number = vehicle_number or driver.vehicle_number
        
        if lat is None or lon is None:
            return {"broadcasted": False, "reason": "no_location"}
        
        # Update status in Redis
        result = service.update_driver_location(
            driver_id=driver_id,
            lat=lat,
            lon=lon,
            username=username,
            vehicle_number=vehicle_number,
            status=status,
        )
        
        channel_layer = get_channel_layer()
        if not channel_layer:
            return {"broadcasted": False, "reason": "no_channel_layer"}
        
        # Build status change payload
        payload = {
            "type": "driver_status_changed",
            "driver_id": driver_id,
            "status": status,
            "latitude": lat,
            "longitude": lon,
            "username": username,
            "vehicle_number": vehicle_number,
            "message": f"Driver is now {status}",
        }
        
        # Notify passengers in nearby geohashes
        passengers_notified = 0
        geohash = result.get("geohash")
        
        if geohash:
            for gh in get_geohash_neighbors(geohash):
                passengers = service.get_passengers_in_geohash(gh)
                
                for passenger in passengers:
                    try:
                        p_lat = passenger.get("latitude", 0)
                        p_lon = passenger.get("longitude", 0)
                        p_radius = passenger.get("radius", 1500)
                        channel_name = passenger.get("channel_name")
                        
                        if not channel_name:
                            continue
                        
                        distance = calculate_distance(p_lat, p_lon, lat, lon)
                        if distance > p_radius:
                            continue
                        
                        async_to_sync(channel_layer.send)(channel_name, payload)
                        passengers_notified += 1
                        
                    except Exception:
                        pass
        
        # If driver went offline, remove from GEO index
        if status == "offline":
            service.remove_driver(driver_id)
        
        return {
            "broadcasted": True,
            "passengers_notified": passengers_notified,
            "status": status,
        }
        
    except Exception as e:
        logger.exception("broadcast_driver_status failed: %s", e)
        return {"broadcasted": False, "error": str(e)}


# ---------------------- Async Broadcast Functions ----------------------

async def broadcast_driver_location_async(
    driver_id: int,
    lat: float,
    lon: float,
    username: Optional[str] = None,
    vehicle_number: Optional[str] = None,
    status: str = "available",
    force: bool = False,
) -> Dict[str, Any]:
    """Async version of broadcast_driver_location."""
    try:
        if not force and not _should_broadcast(driver_id):
            return {"broadcasted": False, "reason": "rate_limited"}
        
        service = get_async_driver_location_service()
        
        result = await service.update_driver_location(
            driver_id=driver_id,
            lat=lat,
            lon=lon,
            username=username,
            vehicle_number=vehicle_number,
            status=status,
        )
        
        if not result.get("moved") and not force:
            return {"broadcasted": False, "reason": "not_moved", **result}
        
        channel_layer = get_channel_layer()
        if not channel_layer:
            return {"broadcasted": False, "reason": "no_channel_layer", **result}
        
        payload = {
            "type": "driver_location_updated",
            "driver_id": driver_id,
            "latitude": lat,
            "longitude": lon,
            "username": username,
            "vehicle_number": vehicle_number,
            "status": status,
            "geohash": result.get("geohash"),
        }
        
        passengers_notified = 0
        geohash = result.get("geohash")
        
        if geohash:
            for gh in get_geohash_neighbors(geohash):
                passengers = await service.get_passengers_in_geohash(gh)
                
                for passenger in passengers:
                    try:
                        p_lat = passenger.get("latitude", 0)
                        p_lon = passenger.get("longitude", 0)
                        p_radius = passenger.get("radius", 1500)
                        channel_name = passenger.get("channel_name")
                        
                        if not channel_name:
                            continue
                        
                        distance = calculate_distance(p_lat, p_lon, lat, lon)
                        if distance > p_radius:
                            continue
                        
                        await channel_layer.send(channel_name, payload)
                        passengers_notified += 1
                        
                    except Exception:
                        pass
        
        return {
            "broadcasted": True,
            "passengers_notified": passengers_notified,
            "geohash": geohash,
            **result,
        }
        
    except Exception as e:
        logger.exception("broadcast_driver_location_async failed: %s", e)
        return {"broadcasted": False, "error": str(e)}


async def broadcast_driver_status_async(
    driver_id: int,
    status: str,
    lat: Optional[float] = None,
    lon: Optional[float] = None,
    username: Optional[str] = None,
    vehicle_number: Optional[str] = None,
) -> Dict[str, Any]:
    """Async version of broadcast_driver_status."""
    try:
        service = get_async_driver_location_service()
        
        if lat is None or lon is None:
            driver = await service.get_driver_location(driver_id)
            if driver:
                lat = driver.latitude
                lon = driver.longitude
                username = username or driver.username
                vehicle_number = vehicle_number or driver.vehicle_number
        
        if lat is None or lon is None:
            return {"broadcasted": False, "reason": "no_location"}
        
        result = await service.update_driver_location(
            driver_id=driver_id,
            lat=lat,
            lon=lon,
            username=username,
            vehicle_number=vehicle_number,
            status=status,
        )
        
        channel_layer = get_channel_layer()
        if not channel_layer:
            return {"broadcasted": False, "reason": "no_channel_layer"}
        
        payload = {
            "type": "driver_status_changed",
            "driver_id": driver_id,
            "status": status,
            "latitude": lat,
            "longitude": lon,
            "username": username,
            "vehicle_number": vehicle_number,
            "message": f"Driver is now {status}",
        }
        
        passengers_notified = 0
        geohash = result.get("geohash")
        
        if geohash:
            for gh in get_geohash_neighbors(geohash):
                passengers = await service.get_passengers_in_geohash(gh)
                
                for passenger in passengers:
                    try:
                        p_lat = passenger.get("latitude", 0)
                        p_lon = passenger.get("longitude", 0)
                        p_radius = passenger.get("radius", 1500)
                        channel_name = passenger.get("channel_name")
                        
                        if not channel_name:
                            continue
                        
                        distance = calculate_distance(p_lat, p_lon, lat, lon)
                        if distance > p_radius:
                            continue
                        
                        await channel_layer.send(channel_name, payload)
                        passengers_notified += 1
                        
                    except Exception:
                        pass
        
        if status == "offline":
            await service.remove_driver(driver_id)
        
        return {
            "broadcasted": True,
            "passengers_notified": passengers_notified,
            "status": status,
        }
        
    except Exception as e:
        logger.exception("broadcast_driver_status_async failed: %s", e)
        return {"broadcasted": False, "error": str(e)}
