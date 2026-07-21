import re

from fastapi import APIRouter, Query
from sqlalchemy import text

from ..dependencies import CurrentUser, PgSession
from ..schemas import SpeedLimitOut

router = APIRouter(tags=["speed-limits"])

# How far (in meters) to search for a tagged road around the given point
# Flutter app samples location roughly every 50m while driving, so this gives a buffer above that 
# so pings landing between two samples still find a nearby match

SEARCH_RADIUS_METERS = 75

# Captures only numeric part of the speed in mph
_MPH_PATTERN = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*mph\s*$", re.IGNORECASE)
# Captures only numeric part of the speed in kmh, converts to mph
_KMH_PATTERN = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*km/?h\s*$", re.IGNORECASE)
# Captures only a bare number, assumed to be mph since this extract is US roads
_BARE_NUMBER_PATTERN = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*$")

KMH_TO_MPH = 0.621371


def parse_maxspeed_to_mph(raw: str | None) -> float | None:
    """Normalize an OSM `maxspeed` tag value into a plain mph float.

    Handles the formats actually seen in this dataset: "NN mph", bare "NN" (assumed mph, 
    since this extract is US roads), and "NN km/h" for any non-US segments that slip in 
    Anything else (like "unposted" or "signals") returns None rather than raising, 
    so one bad row doesn't break the query
    """
    if raw is None:
        return None

    if match := _MPH_PATTERN.match(raw):
        return float(match.group(1))

    if match := _KMH_PATTERN.match(raw):
        return round(float(match.group(1)) * KMH_TO_MPH, 1)

    if match := _BARE_NUMBER_PATTERN.match(raw):
        return float(match.group(1))

    return None


# Finds the closest `highway` line segment with a maxspeed tag within SEARCH_RADIUS_METERS of the given point. 
# `way` is stored in SRID 3857 (meters), so the incoming lat/lng (SRID 4326) is transformed to match before distance comparisons

_NEAREST_ROAD_SQL = text(
    """
    SELECT
        name,
        tags -> 'maxspeed' AS maxspeed,
        ST_Distance(way, ST_Transform(:point, 3857)) AS distance_meters
    FROM planet_osm_line
    WHERE highway IS NOT NULL
      AND tags -> 'maxspeed' IS NOT NULL
      AND ST_DWithin(way, ST_Transform(:point, 3857), :radius)
    ORDER BY way <-> ST_Transform(:point, 3857)
    LIMIT 1
    """
)


@router.get("/speed-limit", response_model=SpeedLimitOut)
def get_speed_limit(
    current_user: CurrentUser,
    pg_db: PgSession,
    lat: float = Query(..., ge=-90, le=90),
    lng: float = Query(..., ge=-180, le=180),
):
    # ST_MakePoint takes (lng, lat) and ST_SetSRID marks it as WGS84 (GPS coords)
    point_wkt = f"SRID=4326;POINT({lng} {lat})"

    row = pg_db.execute(
        _NEAREST_ROAD_SQL,
        {"point": point_wkt, "radius": SEARCH_RADIUS_METERS},
    ).first()

    if row is None:
        return SpeedLimitOut(speed_limit_mph=None)

    return SpeedLimitOut(
        speed_limit_mph=parse_maxspeed_to_mph(row.maxspeed),
        road_name=row.name,
        distance_meters=round(row.distance_meters, 1),
    )