"""Tests for GET /driving-reports.

These cover the response contract - what the endpoint promises to return, how
many rows it will hand back, and what it keeps out of the payload. They do not
exercise the query itself, which needs the live MySQL driving_reports and
violations tables.
"""

from datetime import datetime

import pytest
from pydantic import ValidationError

from app import models
from app.main import app
from app.schemas import (
    DEFAULT_REPORT_LIMIT,
    MAX_REPORT_LIMIT,
    VIOLATION_TYPES,
    DrivingReportsOut,
    DrivingReportWithViolationsOut,
)


def report_row(violations: list[models.Violation] | None = None) -> models.DrivingReport:
    """A saved report as it comes back off the table, with no session needed."""
    return models.DrivingReport(
        id=7,
        user_id=1,
        overall_grade=87.0,
        speed_grade=87.0,
        braking_grade=90.0,
        acceleration_grade=92.0,
        turning_grade=88.0,
        focus_grade=95.0,
        report_date=datetime(2026, 7, 30, 10, 30),
        trip_duration_minutes=30.0,
        trip_distance_miles=12.4,
        violations=violations or [],
    )


def violation_row(**overrides) -> models.Violation:
    fields = {
        "id": 3,
        "user_id": 1,
        "driving_report_id": 7,
        "violation_type": "Proper Speed",
        "road_name": "Roosevelt Blvd",
        "start_time": datetime(2026, 7, 30, 10, 5),
        "end_time": datetime(2026, 7, 30, 10, 5, 18),
    }
    fields.update(overrides)
    return models.Violation(**fields)


def get_operation() -> dict:
    # Included routers aren't flattened into app.routes in this FastAPI version,
    # so the generated OpenAPI schema is the reliable view of what's mounted
    return app.openapi()["paths"]["/driving-reports"]["get"]


def test_route_is_registered_and_requires_a_token() -> None:
    operation = get_operation()
    assert operation["security"] == [{"HTTPBearer": []}]
    assert "200" in operation["responses"]


def test_limit_is_optional_and_bounded() -> None:
    # Without bounds, a caller could ask for an entire history plus every
    # violation under it in one request
    limit = next(p for p in get_operation()["parameters"] if p["name"] == "limit")
    assert limit["in"] == "query"
    assert limit["required"] is False
    assert limit["schema"]["default"] == DEFAULT_REPORT_LIMIT
    assert limit["schema"]["minimum"] == 1
    assert limit["schema"]["maximum"] == MAX_REPORT_LIMIT


def test_violation_types_are_the_five_graded_dimensions() -> None:
    # These strings are the violations.violation_type ENUM labels in MySQL. If
    # they drift, writes fail at INSERT and reads reject rows that are fine
    assert VIOLATION_TYPES == (
        "Proper Speed",
        "Smooth Braking",
        "Smooth Accelerating",
        "Smooth Turning",
        "Focused Driving",
    )


def test_a_report_carries_its_violations_in_camel_case() -> None:
    # The endpoint hands the ORM rows to the response model, which only works
    # while both out-schemas have from_attributes set
    body = DrivingReportWithViolationsOut.model_validate(
        report_row([violation_row()])
    ).model_dump(by_alias=True)

    assert body["id"] == 7
    assert body["speedGrade"] == 87.0
    assert len(body["violations"]) == 1

    violation = body["violations"][0]
    assert violation["violationType"] == "Proper Speed"
    assert violation["roadName"] == "Roosevelt Blvd"
    assert violation["startTime"] == datetime(2026, 7, 30, 10, 5)
    assert violation["endTime"] == datetime(2026, 7, 30, 10, 5, 18)
    assert "violation_type" not in violation


def test_a_clean_trip_serializes_an_empty_violations_list() -> None:
    body = DrivingReportWithViolationsOut.model_validate(report_row()).model_dump(
        by_alias=True
    )
    assert body["violations"] == []


def test_a_missing_road_name_is_allowed() -> None:
    # The speed-limit lookup returns no road name off-road or outside the OSM
    # extract, and the column is nullable to match
    body = DrivingReportWithViolationsOut.model_validate(
        report_row([violation_row(road_name=None)])
    ).model_dump(by_alias=True)
    assert body["violations"][0]["roadName"] is None


def test_the_response_hides_user_ids() -> None:
    body = DrivingReportsOut(reports=[report_row([violation_row()])]).model_dump(
        by_alias=True
    )
    report = body["reports"][0]
    assert "userId" not in report
    assert "userId" not in report["violations"][0]
    assert "drivingReportId" not in report["violations"][0]


def test_an_unknown_violation_type_is_rejected() -> None:
    with pytest.raises(ValidationError):
        DrivingReportWithViolationsOut.model_validate(
            report_row([violation_row(violation_type="Tailgating")])
        )
