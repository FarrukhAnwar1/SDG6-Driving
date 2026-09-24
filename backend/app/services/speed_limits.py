"""Decide which speed limit the grader should use for a stretch of road.

The nearest-road lookup itself lives in two places - the `/speed-limit`
endpoint the app polls while driving, and the road-name resolution that runs
when a report is uploaded. What lives here is everything those two have to
agree on: which OSM `highway` values a car can actually be on, how a `maxspeed`
tag becomes a number, and what to assume when a road carries no tag at all.

Why the assumptions exist: `maxspeed` coverage in this extract is good on the
roads that carry the most driving (trunk 98%, motorway 95%, primary 90%,
secondary 58%) and poor everywhere else - residential is 8.6% of 584k ways.
A lookup that only answers for tagged roads therefore says nothing about
neighbourhood driving, which is where a 25 mph limit matters most. The numbers
below come from the extract itself rather than from a table someone wrote down;
see README for the queries that produced them.
"""

import re

# How far (in meters) to search for a road around the given point. The Flutter
# app samples location roughly every 50m while driving, so this gives a buffer
# above that. Shared by both queries: matching radii is part of what makes a
# violation resolve to the road the driver was actually graded against
SEARCH_RADIUS_METERS = 75

# OSM tags every road AND every path with `highway`, so the tag alone doesn't
# mean a car can be there. Restricting to these values keeps the lookup off the
# ~773k footways, paths, cycleways, tracks, steps and corridors in this extract,
# and off `construction`/`proposed` ways, which are 23.5% maxspeed-tagged and so
# would otherwise match on roads that may not exist yet.
#
# `service` (driveways, parking aisles, alleys) IS included: a driver sitting in
# a parking lot should resolve to the aisle they're on rather than to an
# arterial 70m away. It carries no assumed limit, so it reads as ungraded
DRIVEABLE_HIGHWAY_TYPES = (
    "motorway",
    "trunk",
    "primary",
    "secondary",
    "tertiary",
    "unclassified",
    "residential",
    "living_street",
    "service",
    "busway",
    "road",
    "motorway_link",
    "trunk_link",
    "primary_link",
    "secondary_link",
    "tertiary_link",
)

# Tolerance applied to a limit that came off the road itself
POSTED_SPEEDING_THRESHOLD_MPH = 5.0

# What to assume on a road with no usable `maxspeed`, as
# {highway: (assumed_limit_mph, speeding_threshold_mph)}.
#
# A class earns an entry only when its tagged ways cluster tightly enough that
# one number describes it. Each threshold is derived rather than picked: it is
# wide enough that a driver doing the real limit on the highest plausible
# posting for that class still doesn't register as speeding.
#
#   residential   25 mph on 68.4% of 50,546 tagged ways, and 30 mph is the
#                 practical ceiling (25+30 = 79.7%, 35 is under 4%). Tolerance
#                 of 10 = (30 ceiling - 25 assumed) + 5 normal, so 30 in a real
#                 30 never fires and 35+ always does. Also matches PA's 25 mph
#                 statutory urban-district limit, which is the legal backstop
#   unclassified  25 mph on 35.9% of 2,794 - a weaker mode with a 35 mph tail,
#                 so it takes a wider 15 = (35 - 25) + 5
#   living_street 88 tagged ways total, spread 5-25, mode 10. Barely 1,240 ways
#                 in the extract, so the number matters little either way
#
# Deliberately absent, because assuming a number would invent violations:
#   tertiary      30/35/40/45 at 33/25/13/12% - no mode to speak of. Assume 30
#                 and a driver legally doing 50 on a real 45 reads as 20 over
#   secondary     same flat shape, and already 58% tagged
#   service       modal 15, but grading someone's driveway is not the point
#   *_link        ramps vary far too much to guess at
#   motorway etc. already 90%+ tagged; an untagged one is an outlier, not a gap
INFERRED_SPEED_LIMITS_MPH: dict[str, tuple[float, float]] = {
    "residential": (25.0, 10.0),
    "unclassified": (25.0, 15.0),
    "living_street": (15.0, 10.0),
}

# Captures only numeric part of the speed in mph
_MPH_PATTERN = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*mph\s*$", re.IGNORECASE)
# Captures only numeric part of the speed in kmh, converts to mph
_KMH_PATTERN = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*km/?h\s*$", re.IGNORECASE)
# Captures only a bare number, assumed to be mph since this extract is US roads
_BARE_NUMBER_PATTERN = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*$")

KMH_TO_MPH = 0.621371


def parse_maxspeed_to_mph(raw: str | None) -> float | None:
    """Normalize an OSM `maxspeed` tag value into a plain mph float.

    Handles the formats actually seen in this dataset: "NN mph", bare "NN"
    (assumed mph, since this extract is US roads), and "NN km/h" for any non-US
    segments that slip in. Anything else (like "unposted" or a "30-35 mph"
    range) returns None rather than raising, so one bad row doesn't break the
    query - and, since None falls through to the assumed limit for the road's
    class, "unposted" lands on the statutory default instead of on nothing,
    which is what the tag is stating in the first place.

    Between them these cover all but 31 of the 210,340 tagged ways in the
    extract, so the unparsed tail is not worth chasing further.
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


def resolve_speed_limit(
    maxspeed_tag: str | None,
    highway: str | None,
    infer: bool = False,
) -> tuple[float | None, str, float | None]:
    """Settle on a limit for one road, as (limit_mph, source, threshold_mph).

    `source` tells the caller how much to trust the number:

      "posted"   read off the road's own `maxspeed` tag
      "inferred" assumed from the road's class, because it carries no usable
                 tag - see INFERRED_SPEED_LIMITS_MPH for which classes qualify
      "unknown"  no tag and no assumption worth making, so the limit is None
                 and the caller should treat the stretch as ungraded

    The threshold travels with the limit rather than living on the client,
    because how much slack a limit deserves depends on how tightly that road
    class's postings cluster in the extract - which is knowledge this side of
    the wire has and the app doesn't. It is None exactly when the limit is.

    `infer` gates the assumed limits only; a posted limit is returned either
    way. It is off by default because an assumed limit is only safe to grade
    against once the client honours the threshold sent alongside it - grading
    an assumed 25 at the flat 5 mph tolerance the app uses today would flag a
    driver legally doing 30 on a residential street posted 30. See
    settings.speed_limit_inference_enabled.
    """
    posted = parse_maxspeed_to_mph(maxspeed_tag)
    if posted is not None:
        return posted, "posted", POSTED_SPEEDING_THRESHOLD_MPH

    if not infer:
        return None, "unknown", None

    assumed = INFERRED_SPEED_LIMITS_MPH.get(highway or "")
    if assumed is None:
        return None, "unknown", None

    limit_mph, threshold_mph = assumed
    return limit_mph, "inferred", threshold_mph
