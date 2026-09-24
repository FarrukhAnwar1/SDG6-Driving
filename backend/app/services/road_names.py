"""Turn the coordinates the app records into the road names violations stores.

Each grading service notes where a violation began, but violations has a
road_name column and no geometry, so the points have to be resolved on the way
in and then dropped. The lookup runs against the same PostGIS road data behind
GET /speed-limit, so a violation names the road the app was reading a limit
from when it recorded it.
"""

import logging
from typing import Sequence

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from .speed_limits import DRIVEABLE_HIGHWAY_TYPES, SEARCH_RADIUS_METERS

logger = logging.getLogger(__name__)

# violations.road_name is varchar(255). OSM names are far shorter, but a long
# one would fail the INSERT, and losing a trip over a road's name is not a trade
# worth making
MAX_ROAD_NAME_LENGTH = 255

# Resolves every point in one round trip: the supplied coordinates become a
# derived table, and the LATERAL join picks each one's nearest named road.
# Doing this per violation instead would mean one query per row.
#
# `way` is stored in SRID 3857 (meters), so the incoming lat/lng (SRID 4326) is
# transformed once per point and compared in that projection. It searches the
# same radius and the same road classes as GET /speed-limit, which is what makes
# a violation name the road the driver was actually graded against - the two
# used to filter differently and could disagree about which road a point was on.
# The extra `name` filter is this query's own: an unnamed road is no use as a
# label, and LEFT JOIN keeps points with no match in the result as NULL, so the
# output stays aligned with the input.
_ROAD_NAMES_SQL = text(
    """
    SELECT point.idx AS idx, road.name AS road_name
    FROM (
        SELECT
            supplied.idx AS idx,
            ST_Transform(
                ST_SetSRID(ST_MakePoint(supplied.lng, supplied.lat), 4326), 3857
            ) AS geom
        FROM unnest(
                CAST(:lngs AS double precision[]),
                CAST(:lats AS double precision[])
             ) WITH ORDINALITY AS supplied(lng, lat, idx)
    ) AS point
    LEFT JOIN LATERAL (
        SELECT name
        FROM planet_osm_line
        WHERE highway = ANY(CAST(:driveable AS text[]))
          AND name IS NOT NULL
          AND ST_DWithin(way, point.geom, :radius)
        ORDER BY way <-> point.geom
        LIMIT 1
    ) AS road ON TRUE
    """
)


def resolve_road_names(
    pg_db: Session, points: Sequence[tuple[float, float]]
) -> list[str | None]:
    """Name the nearest road to each (latitude, longitude), in the same order.

    An entry is None when nothing was found - the point is off-road, outside the
    OSM extract's coverage, or the nearest road is unnamed - which is why the
    column is nullable.
    """
    if not points:
        return []

    lats = [latitude for latitude, _ in points]
    lngs = [longitude for _, longitude in points]

    try:
        rows = pg_db.execute(
            _ROAD_NAMES_SQL,
            {
                "lats": lats,
                "lngs": lngs,
                "radius": SEARCH_RADIUS_METERS,
                "driveable": list(DRIVEABLE_HIGHWAY_TYPES),
            },
        ).all()
    except SQLAlchemyError:
        # The road data is a separate database from the one the report is being
        # written to. If it's unreachable the drive is still worth keeping, so
        # the violations save with no road name rather than the upload failing.
        # Rolled back so the session is clean for whatever holds it next
        logger.warning(
            "Road name lookup failed; saving %d violation(s) without road names",
            len(points),
            exc_info=True,
        )
        pg_db.rollback()
        return [None] * len(points)

    names: list[str | None] = [None] * len(points)
    for row in rows:
        # WITH ORDINALITY counts from 1
        names[row.idx - 1] = (
            row.road_name[:MAX_ROAD_NAME_LENGTH] if row.road_name else None
        )
    return names
