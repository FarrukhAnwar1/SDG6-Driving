"""Tests for the violations half of POST /driving-reports.

These cover what the endpoint accepts from the app, how coordinates become road
names, and what gets handed to the tables. The MySQL write and the PostGIS
query are stubbed (both need live databases) but the shape of the rows and
the ordering contract between the two are checked here, since a mismatch there
would silently attach a violation to the wrong road.
"""

from datetime import datetime

import pytest
from pydantic import ValidationError
from sqlalchemy.exc import OperationalError

from app import models
from app.main import app
from app.schemas import (
    MAX_VIOLATIONS_PER_REPORT,
    VIOLATION_TYPES,
    DrivingReportCreate,
    DrivingReportWithViolationsOut,
)
from app.services.driving_reports import write_driving_report
from app.services.road_names import MAX_ROAD_NAME_LENGTH, resolve_road_names


def valid_violation(**overrides) -> dict:
    """One violation as the Flutter grading services record it."""
    body = {
        "violationType": "Proper Speed",
        "startTime": "2026-07-30T10:05:00",
        "endTime": "2026-07-30T10:05:18",
        "latitude": 40.0379,
        "longitude": -75.0182,
    }
    body.update(overrides)
    return body


def valid_report(**overrides) -> dict:
    body = {
        "startedAt": "2026-07-30T10:00:00",
        "endedAt": "2026-07-30T10:30:00",
        "tripDistanceMiles": 12.4,
        "overallGrade": 87.0,
        "speedGrade": 87.0,
    }
    body.update(overrides)
    return body


class FakeResult:
    def __init__(self, rows):
        self._rows = rows

    def all(self):
        return self._rows


class FakeRow:
    """A road-name row as the query returns it, 1-based like WITH ORDINALITY."""

    def __init__(self, idx: int, road_name: str | None):
        self.idx = idx
        self.road_name = road_name


class FakePgSession:
    def __init__(self, rows=(), error: Exception | None = None):
        self._rows = list(rows)
        self._error = error
        self.executed: list[dict] = []
        self.rolled_back = False

    def execute(self, statement, params):
        self.executed.append(params)
        if self._error is not None:
            raise self._error
        return FakeResult(self._rows)

    def rollback(self):
        self.rolled_back = True


class FakeDbSession:
    """Stands in for the MySQL session, capturing what would be inserted."""

    def __init__(self):
        self.added = []
        self.committed = False
        self.refreshed = []

    def add(self, row):
        self.added.append(row)

    def commit(self):
        self.committed = True

    def refresh(self, row):
        self.refreshed.append(row)


# request shape


def test_violations_are_optional() -> None:
    # The client that only sends grades has to keep working unchanged
    report = DrivingReportCreate.model_validate(valid_report())
    assert report.violations == []


def test_a_violation_is_parsed_from_camel_case() -> None:
    report = DrivingReportCreate.model_validate(
        valid_report(violations=[valid_violation()])
    )
    violation = report.violations[0]
    assert violation.violation_type == "Proper Speed"
    assert violation.start_time == datetime(2026, 7, 30, 10, 5)
    assert violation.end_time == datetime(2026, 7, 30, 10, 5, 18)
    assert violation.latitude == 40.0379
    assert violation.longitude == -75.0182


@pytest.mark.parametrize("violation_type", VIOLATION_TYPES)
def test_every_enum_label_is_accepted(violation_type: str) -> None:
    # TripSummary keeps four separate violation lists and all five ENUM labels have
    # to arrive through this one field
    report = DrivingReportCreate.model_validate(
        valid_report(violations=[valid_violation(violationType=violation_type)])
    )
    assert report.violations[0].violation_type == violation_type


def test_an_unknown_violation_type_is_rejected() -> None:
    # violation_type is a MySQL ENUM
    # an unlisted label fails at INSERT, so it has to be a 422 rather than a 500
    with pytest.raises(ValidationError):
        DrivingReportCreate.model_validate(
            valid_report(violations=[valid_violation(violationType="Tailgating")])
        )


def test_extra_grading_fields_are_ignored_not_rejected() -> None:
    # The grading services attach these to their violations and none has a
    # column. The upload must not fail because the client sent its whole object
    report = DrivingReportCreate.model_validate(
        valid_report(
            violations=[
                valid_violation(
                    speedLimitMph=35.0, peakSpeedMph=52.0, peakGForce=0.42,
                    speedAtStartMph=31.0, durationSeconds=18,
                )
            ]
        )
    )
    violation = report.violations[0]
    assert violation.violation_type == "Proper Speed"
    assert not hasattr(violation, "peak_speed_mph")


def test_rejects_a_violation_that_ends_before_it_starts() -> None:
    # violations carries CHECK (end_time >= start_time)
    with pytest.raises(ValidationError, match="endTime must not be earlier"):
        DrivingReportCreate.model_validate(
            valid_report(
                violations=[valid_violation(endTime="2026-07-30T10:04:00")]
            )
        )


def test_accepts_an_instantaneous_violation() -> None:
    # The CHECK is >=, so equal timestamps are storable
    report = DrivingReportCreate.model_validate(
        valid_report(violations=[valid_violation(endTime="2026-07-30T10:05:00")])
    )
    assert report.violations[0].end_time == report.violations[0].start_time


@pytest.mark.parametrize(
    "field, bad_value",
    [("latitude", 91), ("latitude", -91), ("longitude", 181), ("longitude", -181)],
)
def test_rejects_impossible_coordinates(field: str, bad_value: float) -> None:
    with pytest.raises(ValidationError):
        DrivingReportCreate.model_validate(
            valid_report(violations=[valid_violation(**{field: bad_value})])
        )


@pytest.mark.parametrize("field", ["violationType", "startTime", "endTime",
                                   "latitude", "longitude"])
def test_violation_fields_are_all_required(field: str) -> None:
    violation = valid_violation()
    del violation[field]
    with pytest.raises(ValidationError):
        DrivingReportCreate.model_validate(valid_report(violations=[violation]))


def test_violation_timestamps_are_normalized_to_naive_utc() -> None:
    # They land in DATETIME columns beside report_date, which carries no zone
    report = DrivingReportCreate.model_validate(
        valid_report(
            violations=[
                valid_violation(
                    startTime="2026-07-30T06:05:00-04:00",
                    endTime="2026-07-30T10:05:18Z",
                )
            ]
        )
    )
    violation = report.violations[0]
    assert violation.start_time == datetime(2026, 7, 30, 10, 5)
    assert violation.start_time.tzinfo is None
    assert violation.end_time.tzinfo is None


def test_the_violation_list_is_capped() -> None:
    too_many = [valid_violation() for _ in range(MAX_VIOLATIONS_PER_REPORT + 1)]
    with pytest.raises(ValidationError):
        DrivingReportCreate.model_validate(valid_report(violations=too_many))


def test_the_cap_itself_is_accepted() -> None:
    at_cap = [valid_violation() for _ in range(MAX_VIOLATIONS_PER_REPORT)]
    report = DrivingReportCreate.model_validate(valid_report(violations=at_cap))
    assert len(report.violations) == MAX_VIOLATIONS_PER_REPORT


# coordinate lookup


def test_no_points_means_no_query() -> None:
    # A clean trip shouldn't touch the PostGIS database at all
    pg_db = FakePgSession()
    assert resolve_road_names(pg_db, []) == []
    assert pg_db.executed == []


def test_names_come_back_in_the_order_the_points_went_in() -> None:
    # The rows are what the join happens to return; position is carried by idx.
    # If this slips, a violation is attributed to another violation's road
    pg_db = FakePgSession(rows=[FakeRow(3, "Cottman Ave"), FakeRow(1, "Roosevelt Blvd")])
    names = resolve_road_names(
        pg_db, [(40.0379, -75.0182), (40.04, -75.02), (40.05, -75.03)]
    )
    assert names == ["Roosevelt Blvd", None, "Cottman Ave"]


def test_points_are_passed_as_matching_lat_lng_arrays() -> None:
    pg_db = FakePgSession(rows=[])
    resolve_road_names(pg_db, [(40.0379, -75.0182), (39.95, -75.16)])
    params = pg_db.executed[0]
    # Swapping these silently looks up a point on the far side of the world
    assert params["lats"] == [40.0379, 39.95]
    assert params["lngs"] == [-75.0182, -75.16]


def test_a_point_with_no_nearby_road_resolves_to_none() -> None:
    # Off-road, or outside the OSM extract's coverage means the column is nullable
    pg_db = FakePgSession(rows=[FakeRow(1, None)])
    assert resolve_road_names(pg_db, [(40.0379, -75.0182)]) == [None]


def test_an_overlong_road_name_is_truncated_to_the_column() -> None:
    pg_db = FakePgSession(rows=[FakeRow(1, "R" * (MAX_ROAD_NAME_LENGTH + 50))])
    (name,) = resolve_road_names(pg_db, [(40.0379, -75.0182)])
    assert len(name) == MAX_ROAD_NAME_LENGTH


def test_an_unreachable_road_database_does_not_lose_the_trip() -> None:
    # PostGIS and MySQL are separate databases. Losing the names is recoverable,
    # losing the drive is not
    pg_db = FakePgSession(
        error=OperationalError("SELECT 1", {}, Exception("connection refused"))
    )
    names = resolve_road_names(pg_db, [(40.0379, -75.0182), (39.95, -75.16)])
    assert names == [None, None]
    assert pg_db.rolled_back


# what's written


def test_the_report_and_its_violations_are_written_together() -> None:
    payload = DrivingReportCreate.model_validate(
        valid_report(
            violations=[
                valid_violation(),
                valid_violation(violationType="Smooth Braking"),
            ]
        )
    )
    db = FakeDbSession()

    report = write_driving_report(db, 42, payload, ["Roosevelt Blvd", None])

    # One add for the parent: the violations ride along on the relationship, so
    # the whole trip commits or none of it does
    assert db.added == [report]
    assert db.committed
    assert report.user_id == 42
    assert report.report_date == datetime(2026, 7, 30, 10, 30)
    assert report.trip_duration_minutes == 30.0

    first, second = report.violations
    assert first.violation_type == "Proper Speed"
    assert first.road_name == "Roosevelt Blvd"
    assert first.start_time == datetime(2026, 7, 30, 10, 5)
    assert first.end_time == datetime(2026, 7, 30, 10, 5, 18)
    assert second.violation_type == "Smooth Braking"
    # Nothing was found for this one, and the column takes NULL
    assert second.road_name is None


def test_every_violation_is_stamped_with_the_tokens_user() -> None:
    # user_id is denormalized onto the row and must never come from the body
    payload = DrivingReportCreate.model_validate(
        valid_report(violations=[valid_violation(), valid_violation(userId=999)])
    )
    db = FakeDbSession()

    report = write_driving_report(db, 42, payload, ["Roosevelt Blvd", "Cottman Ave"])

    assert [violation.user_id for violation in report.violations] == [42, 42]


def test_a_clean_trip_writes_no_violations() -> None:
    payload = DrivingReportCreate.model_validate(valid_report())
    db = FakeDbSession()

    report = write_driving_report(db, 42, payload, [])

    assert report.violations == []
    assert db.committed


def test_mismatched_road_names_fail_loudly() -> None:
    # If the lookup ever returned a different number of names than there are
    # violations, zip would silently pair them off and drop the tail
    payload = DrivingReportCreate.model_validate(
        valid_report(violations=[valid_violation(), valid_violation()])
    )
    with pytest.raises(ValueError):
        write_driving_report(FakeDbSession(), 42, payload, ["Roosevelt Blvd"])


# response


def test_the_route_still_requires_a_token() -> None:
    operation = app.openapi()["paths"]["/driving-reports"]["post"]
    assert operation["security"] == [{"HTTPBearer": []}]
    assert "201" in operation["responses"]


def test_the_response_returns_the_saved_violations() -> None:
    # The client learns the road names the server resolved without rereading
    row = models.DrivingReport(
        id=7, user_id=1, overall_grade=87.0, speed_grade=87.0, braking_grade=100.0,
        acceleration_grade=100.0, turning_grade=100.0, focus_grade=100.0,
        report_date=datetime(2026, 7, 30, 10, 30),
        trip_duration_minutes=30.0, trip_distance_miles=12.4,
        violations=[
            models.Violation(
                id=3, user_id=1, driving_report_id=7, violation_type="Proper Speed",
                road_name="Roosevelt Blvd",
                start_time=datetime(2026, 7, 30, 10, 5),
                end_time=datetime(2026, 7, 30, 10, 5, 18),
            )
        ],
    )
    body = DrivingReportWithViolationsOut.model_validate(row).model_dump(by_alias=True)

    assert body["id"] == 7
    assert body["violations"][0]["roadName"] == "Roosevelt Blvd"
    assert body["violations"][0]["violationType"] == "Proper Speed"
    # The coordinates were only ever a means to the road name
    assert "latitude" not in body["violations"][0]
    assert "userId" not in body["violations"][0]


# both tables, end to end

# The tests above stub the session, so they can't see whether SQLAlchemy really
# writes a report and its violations as two linked inserts. These run the
# endpoint against a scratch in-memory database (still no live MySQL) so a
# change that breaks the relationship, the foreign key or the transaction gets
# caught here rather than in the app.


@pytest.fixture
def scratch_db():
    """An empty stand-in for the MySQL schema, with one user to own the trip."""
    from sqlalchemy import create_engine
    from sqlalchemy.orm import sessionmaker
    from sqlalchemy.pool import StaticPool

    from app.database import Base

    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(engine)
    session_factory = sessionmaker(bind=engine)

    with session_factory() as seed:
        seed.add(
            models.User(
                id=1, username="driver", email="driver@example.com", password_hash="x"
            )
        )
        seed.commit()

    yield session_factory
    engine.dispose()


@pytest.fixture
def client(scratch_db):
    from fastapi.testclient import TestClient

    from app.dependencies import get_current_user, get_db, get_pg_db

    def override_db():
        db = scratch_db()
        try:
            yield db
        finally:
            db.close()

    def override_pg():
        # The road data is queried through this session; the lookup itself is
        # covered above, so hand back a fixed name per point
        yield FakePgSession(rows=[FakeRow(1, "Roosevelt Blvd"), FakeRow(2, None)])

    def override_user():
        with scratch_db() as db:
            return db.get(models.User, 1)

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_pg_db] = override_pg
    app.dependency_overrides[get_current_user] = override_user

    with TestClient(app) as test_client:
        yield test_client

    app.dependency_overrides.clear()


def test_an_upload_lands_in_both_tables(client, scratch_db) -> None:
    response = client.post(
        "/driving-reports",
        json=valid_report(
            violations=[
                valid_violation(),
                valid_violation(
                    violationType="Smooth Braking",
                    startTime="2026-07-30T10:10:00",
                    endTime="2026-07-30T10:10:02",
                    latitude=0.0,
                    longitude=0.0,
                ),
            ]
        ),
    )

    assert response.status_code == 201
    body = response.json()
    assert body["violations"][0]["roadName"] == "Roosevelt Blvd"
    # Nothing near this point, and the column takes NULL
    assert body["violations"][1]["roadName"] is None

    with scratch_db() as db:
        report = db.query(models.DrivingReport).one()
        violations = db.query(models.Violation).all()

    assert report.user_id == 1
    assert report.report_date == datetime(2026, 7, 30, 10, 30)
    # Both rows point at the report that was just created, and carry its owner
    assert [v.driving_report_id for v in violations] == [report.id, report.id]
    assert [v.user_id for v in violations] == [1, 1]
    assert [v.violation_type for v in violations] == ["Proper Speed", "Smooth Braking"]


def test_a_report_with_no_violations_still_saves(client, scratch_db) -> None:
    response = client.post("/driving-reports", json=valid_report())

    assert response.status_code == 201
    assert response.json()["violations"] == []
    with scratch_db() as db:
        assert db.query(models.DrivingReport).count() == 1
        assert db.query(models.Violation).count() == 0


def test_a_rejected_body_writes_nothing(client, scratch_db) -> None:
    response = client.post(
        "/driving-reports",
        json=valid_report(violations=[valid_violation(violationType="Tailgating")]),
    )

    assert response.status_code == 422
    with scratch_db() as db:
        assert db.query(models.DrivingReport).count() == 0
        assert db.query(models.Violation).count() == 0
