# Answers "what's the limit where I am right now?" for the live dashboard,
# which polls this every 4 seconds while a trip is running. The decision of
# what the limit actually is lives in services/speed_limits.py; this file runs
# the nearest-road query and shapes the response.
from fastapi import APIRouter, Query
from sqlalchemy import text

from ..config import settings
from ..dependencies import CurrentUser, PgSession
from ..schemas import SpeedLimitOut
from ..services.speed_limits import (
    DRIVEABLE_HIGHWAY_TYPES,
    SEARCH_RADIUS_METERS,
    resolve_speed_limit,
)

router = APIRouter(tags=["speed-limits"])

# Finds the closest driveable line segment within SEARCH_RADIUS_METERS of the
# given point. `way` is stored in SRID 3857 (meters), so the incoming lat/lng
# (SRID 4326) is transformed to match before distance comparisons.
#
# Note this does NOT filter on maxspeed. Doing so returned the nearest road
# *that happened to be tagged*, which on an untagged residential street meant
# answering with an arterial's 45 up to 75m away - wrong limit, wrong road
# name, and wrong grading. The nearest driveable road is the honest answer;
# whether it has a limit is then resolve_speed_limit's problem.
_NEAREST_ROAD_SQL = text(
    """
    SELECT
        name,
        highway,
        tags -> 'maxspeed' AS maxspeed,
        ST_Distance(way, ST_Transform(:point, 3857)) AS distance_meters
    FROM planet_osm_line
    WHERE highway = ANY(CAST(:driveable AS text[]))
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
        {
            "point": point_wkt,
            "radius": SEARCH_RADIUS_METERS,
            "driveable": list(DRIVEABLE_HIGHWAY_TYPES),
        },
    ).first()

    if row is None:
        return SpeedLimitOut(speed_limit_mph=None)

    speed_limit_mph, source, threshold_mph = resolve_speed_limit(
        row.maxspeed,
        row.highway,
        infer=settings.speed_limit_inference_enabled,
    )

    # The road name and distance come back even when the limit doesn't, so the
    # app can still say where it thinks the driver is while grading nothing
    return SpeedLimitOut(
        speed_limit_mph=speed_limit_mph,
        speed_limit_source=source,
        speeding_threshold_mph=threshold_mph,
        road_name=row.name,
        distance_meters=round(row.distance_meters, 1),
    )
