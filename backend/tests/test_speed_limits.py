"""Tests for how a point on the map becomes a speed limit.

The PostGIS query is stubbed (it needs a live database) so what's checked
here is the decision made on top of a row: which tag values parse, which road
classes carry an assumed limit and which deliberately don't, and that an
assumption never reaches the client labelled as a posted sign.

The road classes both queries filter on are checked against each other too,
since the two drifting apart is what made a violation name a road the driver
was never graded against.
"""

import pytest

from app.routers.speed_limits import _NEAREST_ROAD_SQL
from app.services.road_names import _ROAD_NAMES_SQL
from app.services.speed_limits import (
    DRIVEABLE_HIGHWAY_TYPES,
    INFERRED_SPEED_LIMITS_MPH,
    POSTED_SPEEDING_THRESHOLD_MPH,
    parse_maxspeed_to_mph,
    resolve_speed_limit,
)


# parsing the tag 

@pytest.mark.parametrize(
    "raw, expected",
    [
        # The four shapes that cover all but 31 of the extract's 210,340 ways
        ("45 mph", 45.0),
        ("25 mph", 25.0),
        ("25mph", 25.0),  # no space, 9 ways
        ("40", 40.0),  # bare number, assumed mph on a US extract
        ("14.5 mph", 14.5),
        ("37.015", 37.015),
    ],
)
def test_parses_the_values_this_extract_actually_contains(raw, expected) -> None:
    assert parse_maxspeed_to_mph(raw) == expected


def test_kmh_is_converted() -> None:
    assert parse_maxspeed_to_mph("100 km/h") == 62.1
    assert parse_maxspeed_to_mph("100 kmh") == 62.1


@pytest.mark.parametrize("raw", ["unposted", "30-35 mph", "signals", "none", "", None])
def test_an_unusable_value_is_not_a_crash(raw) -> None:
    # One unparseable row must never take the query down with it
    assert parse_maxspeed_to_mph(raw) is None


# posted limits

def test_a_posted_limit_is_used_as_is() -> None:
    limit, source, threshold = resolve_speed_limit("45 mph", "primary")
    assert (limit, source, threshold) == (45.0, "posted", POSTED_SPEEDING_THRESHOLD_MPH)


def test_a_posted_limit_does_not_need_inference_turned_on() -> None:
    # The flag gates assumptions only - a road that states its limit is always
    # graded, whatever the rollout state
    assert resolve_speed_limit("30 mph", "residential", infer=False)[0] == 30.0


def test_a_posted_limit_beats_the_assumption_for_its_class() -> None:
    # residential assumes 25; this one says 30, and the road wins
    limit, source, _ = resolve_speed_limit("30 mph", "residential", infer=True)
    assert (limit, source) == (30.0, "posted")


# inferred limits

def test_inference_is_off_by_default() -> None:
    # Off until the app honours the threshold sent with an assumed limit
    assert resolve_speed_limit(None, "residential") == (None, "unknown", None)


def test_a_residential_street_falls_back_to_the_statutory_25() -> None:
    limit, source, threshold = resolve_speed_limit(None, "residential", infer=True)
    assert (limit, source) == (25.0, "inferred")
    # Wide enough that 30 in a real 30 zone never registers as speeding
    assert 25.0 + threshold > 30.0


def test_unposted_lands_on_the_assumption_rather_than_on_nothing() -> None:
    # "unposted" is a mapper stating the statutory default applies, so it
    # should resolve the same as an untagged road of that class
    assert resolve_speed_limit("unposted", "residential", infer=True) == (
        resolve_speed_limit(None, "residential", infer=True)
    )


@pytest.mark.parametrize("highway", ["tertiary", "secondary", "service"])
def test_classes_with_no_usable_mode_are_left_ungraded(highway) -> None:
    # Their tagged ways are spread too wide for one number to describe, so
    # assuming one would invent violations on roads where nothing was wrong
    assert resolve_speed_limit(None, highway, infer=True) == (None, "unknown", None)


@pytest.mark.parametrize("highway", ["motorway_link", "primary_link", "trunk_link"])
def test_ramps_are_left_ungraded(highway) -> None:
    assert resolve_speed_limit(None, highway, infer=True) == (None, "unknown", None)


def test_an_unrecognised_class_is_ungraded_rather_than_an_error() -> None:
    assert resolve_speed_limit(None, "teleporter", infer=True)[1] == "unknown"
    assert resolve_speed_limit(None, None, infer=True)[1] == "unknown"


def test_every_assumed_class_is_one_the_lookup_can_return() -> None:
    # An assumption for a class the query filters out would be dead code
    for highway in INFERRED_SPEED_LIMITS_MPH:
        assert highway in DRIVEABLE_HIGHWAY_TYPES


def test_an_assumed_limit_always_gets_more_slack_than_a_posted_one() -> None:
    for limit_mph, threshold_mph in INFERRED_SPEED_LIMITS_MPH.values():
        assert threshold_mph > POSTED_SPEEDING_THRESHOLD_MPH
        assert limit_mph > 0


def test_a_limit_and_its_threshold_are_present_together() -> None:
    for tag, highway in [("45 mph", "primary"), (None, "residential"), (None, "tertiary")]:
        limit, _, threshold = resolve_speed_limit(tag, highway, infer=True)
        assert (limit is None) == (threshold is None)


# the two queries agreeing

def test_neither_query_can_match_a_road_a_car_cannot_drive_on() -> None:
    # 773k footways/paths/cycleways/tracks in the extract, plus construction
    # and proposed ways that may not exist yet
    for excluded in [
        "footway",
        "path",
        "cycleway",
        "track",
        "steps",
        "pedestrian",
        "corridor",
        "bridleway",
        "construction",
        "proposed",
    ]:
        assert excluded not in DRIVEABLE_HIGHWAY_TYPES


def test_a_parking_aisle_is_matched_but_not_graded() -> None:
    # Included so a driver in a parking lot resolves to the aisle they're on
    # rather than to an arterial 70m away, but carrying no assumed limit
    assert "service" in DRIVEABLE_HIGHWAY_TYPES
    assert "service" not in INFERRED_SPEED_LIMITS_MPH


def test_both_lookups_filter_on_the_same_road_classes() -> None:
    # The speed-limit query and the violation road-name query have to agree
    # about which road a point is on, or a violation names one road while the
    # grade behind it came from another
    filter_sql = "highway = ANY(CAST(:driveable AS text[]))"
    assert filter_sql in str(_NEAREST_ROAD_SQL)
    assert filter_sql in str(_ROAD_NAMES_SQL)


def test_the_speed_limit_query_no_longer_filters_on_maxspeed() -> None:
    # Filtering there returned the nearest road (that happened to be tagged),
    # which on an untagged street meant answering with a different road's limit
    assert "maxspeed' IS NOT NULL" not in str(_NEAREST_ROAD_SQL)
