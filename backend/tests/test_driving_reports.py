"""Tests for POST /driving-reports.

These cover the request contract - what the endpoint accepts, what it rejects,
and what it puts on the wire. They do not exercise the database write, which
needs the live MySQL driving_reports table.
"""

from datetime import datetime, timedelta

import pytest
from pydantic import ValidationError

from app.main import app
from app.schemas import (
    MAX_TRIP_DISTANCE_MILES,
    UNGRADED_DIMENSION,
    DrivingReportCreate,
    DrivingReportOut,
)


def valid_report(**overrides) -> dict:
    """A well-formed body, as the Flutter client would send it today."""
    body = {
        "startedAt": "2026-07-30T10:00:00",
        "endedAt": "2026-07-30T10:30:00",
        "tripDistanceMiles": 12.4,
        "overallGrade": 87.0,
        "speedGrade": 87.0,
    }
    body.update(overrides)
    return body


def test_route_is_registered_and_requires_a_token() -> None:
    # Included routers aren't flattened into app.routes in this FastAPI version,
    # so the generated OpenAPI schema is the reliable view of what's mounted
    operation = app.openapi()["paths"]["/driving-reports"]["post"]
    assert operation["security"] == [{"HTTPBearer": []}]
    assert "201" in operation["responses"]


def test_accepts_the_fields_the_app_can_send_today() -> None:
    # The app only grades speed, so the other four dimensions must be optional
    report = DrivingReportCreate.model_validate(valid_report())
    assert report.speed_grade == 87.0
    assert report.trip_distance_miles == 12.4


def test_ungraded_dimensions_default_to_full_marks() -> None:
    report = DrivingReportCreate.model_validate(valid_report())
    assert report.braking_grade == UNGRADED_DIMENSION
    assert report.acceleration_grade == UNGRADED_DIMENSION
    assert report.turning_grade == UNGRADED_DIMENSION
    assert report.focus_grade == UNGRADED_DIMENSION


def test_ungraded_dimensions_can_be_supplied_once_implemented() -> None:
    report = DrivingReportCreate.model_validate(
        valid_report(brakingGrade=72.5, accelerationGrade=64.0, turningGrade=88.0,
                     focusGrade=91.5)
    )
    assert report.braking_grade == 72.5
    assert report.acceleration_grade == 64.0
    assert report.turning_grade == 88.0
    assert report.focus_grade == 91.5


def test_duration_is_derived_in_decimal_minutes() -> None:
    # trip_duration_minutes is DECIMAL(5,2), not a whole number of minutes
    report = DrivingReportCreate.model_validate(
        valid_report(endedAt="2026-07-30T10:30:30")
    )
    assert report.trip_duration_minutes == 30.5


def test_duration_rounds_to_two_places() -> None:
    # 100 seconds is 1.666... minutes, which must not be sent to a DECIMAL(5,2)
    report = DrivingReportCreate.model_validate(
        valid_report(endedAt="2026-07-30T10:01:40")
    )
    assert report.trip_duration_minutes == 1.67


def test_rejects_end_before_start() -> None:
    with pytest.raises(ValidationError, match="endedAt must not be earlier"):
        DrivingReportCreate.model_validate(valid_report(endedAt="2026-07-30T09:00:00"))


def test_rejects_a_trip_too_long_for_the_column() -> None:
    # DECIMAL(5,2) tops out at 999.99 minutes, so a longer trip would overflow
    # the column at INSERT - catch it as a 422 instead of a 500
    with pytest.raises(ValidationError, match="shorter than"):
        DrivingReportCreate.model_validate(valid_report(endedAt="2026-07-31T10:00:00"))


def test_accepts_a_long_but_storable_trip() -> None:
    report = DrivingReportCreate.model_validate(
        valid_report(endedAt="2026-07-30T20:00:00")
    )
    assert report.trip_duration_minutes == 600.0


def test_rejects_a_distance_too_large_for_the_column() -> None:
    with pytest.raises(ValidationError):
        DrivingReportCreate.model_validate(
            valid_report(tripDistanceMiles=MAX_TRIP_DISTANCE_MILES + 1)
        )


@pytest.mark.parametrize(
    "field, bad_value",
    [
        ("overallGrade", 101),
        ("overallGrade", -1),
        ("speedGrade", 101),
        ("speedGrade", -1),
        ("brakingGrade", 101),
        ("accelerationGrade", -1),
        ("turningGrade", 101),
        ("focusGrade", -1),
        ("tripDistanceMiles", -0.1),
    ],
)
def test_rejects_out_of_range_fields(field: str, bad_value: float) -> None:
    with pytest.raises(ValidationError):
        DrivingReportCreate.model_validate(valid_report(**{field: bad_value}))


@pytest.mark.parametrize(
    "field", ["startedAt", "endedAt", "tripDistanceMiles", "overallGrade", "speedGrade"]
)
def test_required_fields_are_required(field: str) -> None:
    body = valid_report()
    del body[field]
    with pytest.raises(ValidationError):
        DrivingReportCreate.model_validate(body)


def test_body_cannot_reassign_the_report_to_another_user() -> None:
    # The report is attributed from the bearer token, so a user id in the body is
    # ignored rather than honored
    report = DrivingReportCreate.model_validate(valid_report(userId=999))
    assert not hasattr(report, "user_id")


def test_timestamps_are_normalized_to_naive_utc() -> None:
    # report_date is written from ended_at, and MySQL DATETIME carries no zone -
    # a tz-aware value must not land next to naive ones
    report = DrivingReportCreate.model_validate(
        valid_report(startedAt="2026-07-30T06:00:00-04:00", endedAt="2026-07-30T10:30:00Z")
    )
    # -04:00 local is UTC+4
    assert report.started_at == datetime(2026, 7, 30, 10, 0)
    assert report.ended_at == datetime(2026, 7, 30, 10, 30)
    assert report.ended_at.tzinfo is None


def test_mixed_naive_and_aware_timestamps_stay_subtractable() -> None:
    # trip_duration_minutes subtracts these two, which raises TypeError if one is
    # naive and the other isn't
    report = DrivingReportCreate.model_validate(
        valid_report(startedAt="2026-07-30T10:00:00", endedAt="2026-07-30T10:30:00Z")
    )
    assert (report.ended_at - report.started_at) == timedelta(minutes=30)
    assert report.trip_duration_minutes == 30.0


def test_response_is_camel_case_and_hides_user_id() -> None:
    from app import models

    row = models.DrivingReport(
        id=7,
        user_id=1,
        overall_grade=87.0,
        speed_grade=87.0,
        braking_grade=100.0,
        acceleration_grade=100.0,
        turning_grade=100.0,
        focus_grade=100.0,
        report_date=datetime(2026, 7, 30, 10, 30),
        trip_duration_minutes=30.0,
        trip_distance_miles=12.4,
    )
    # The endpoint returns the ORM row directly and lets response_model convert
    # it, which only works while DrivingReportOut has from_attributes set
    body = DrivingReportOut.model_validate(row).model_dump(by_alias=True)

    assert body["id"] == 7
    assert body["tripDurationMinutes"] == 30.0
    assert body["speedGrade"] == 87.0
    assert "trip_duration_minutes" not in body
    assert "userId" not in body
