"""Helpers for creating PostGIS points from API coordinates."""

from geoalchemy2.elements import WKTElement


def geography_point(*, latitude: float, longitude: float) -> WKTElement:
    """Return an SRID 4326 point in PostGIS's required longitude/latitude order."""

    if not -90 <= latitude <= 90:
        raise ValueError("latitude must be between -90 and 90")
    if not -180 <= longitude <= 180:
        raise ValueError("longitude must be between -180 and 180")

    return WKTElement(f"POINT({longitude} {latitude})", srid=4326)
