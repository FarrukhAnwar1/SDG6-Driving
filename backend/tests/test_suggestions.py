"""Exercise real auth, SQL queries, trend math, and SDK parsing without live services."""

from datetime import datetime, timedelta, timezone
import json

from fastapi.testclient import TestClient
import httpx
import jwt
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app import models, schemas
from app.config import settings
from app.database import Base
from app.dependencies import get_db
from app.main import app
from app.security import create_access_token
from app.services import suggestions


def report(index=0, user_id=1, **overrides):
    ended = datetime(2026, 7, 6, 12) + timedelta(days=index * 7)
    fields = {
        "id": user_id * 1000 + index,
        "user_id": user_id,
        **{name: 60 + index * 4 + offset for offset, name in enumerate(suggestions.GRADE_FIELDS)},
        "report_date": ended,
        "trip_duration_minutes": 30 if index < 3 else 60,
        "trip_distance_miles": 10 + index,
        "violations": [models.Violation(
            user_id=user_id,
            violation_type="Proper Speed",
            road_name="Roosevelt Blvd",
            start_time=ended - timedelta(minutes=2),
            end_time=ended - timedelta(minutes=1),
        )],
    }
    fields.update(overrides)
    return models.DrivingReport(**fields)


def history_rows(count=6):
    rows = [report(index) for index in range(count)]
    for index, row in enumerate(rows):
        for violation in row.violations:
            violation.id = index + 1
    return [schemas.DrivingReportWithViolationsOut.model_validate(row) for row in rows]


def seed(engine, rows):
    with Session(engine) as db:
        db.add_all(rows)
        db.commit()


@pytest.fixture(autouse=True)
def isolated_settings(monkeypatch):
    monkeypatch.setattr(settings, "jwt_secret_key", "suggestions-test-signing-key-at-least-32-bytes")
    monkeypatch.setattr(settings, "gemini_api_key", "test-gemini-key")
    monkeypatch.setattr(settings, "gemini_model", "gemini-3.5-flash-lite")
    monkeypatch.setattr(settings, "gemini_timeout_seconds", 30)


@pytest.fixture
def gemini(monkeypatch):
    """Keep the real SDK serialization and parsing, replacing only its HTTP transport."""
    real_client = suggestions.genai.Client
    state = {
        "requests": [],
        "status": 200,
        "body": {
            "candidates": [{
                "finishReason": "STOP",
                "content": {"role": "model", "parts": [{"text": json.dumps({
                    "message": "Your grades are steadily improving. Keep working on consistent speed control."
                })}]},
            }],
        },
    }

    def handle(request):
        state["requests"].append(request)
        if "error" in state:
            raise state["error"]
        return httpx.Response(state["status"], json=state["body"])

    def client_factory(**kwargs):
        state["options"] = kwargs["http_options"]
        kwargs["http_options"].client_args = {
            "transport": httpx.MockTransport(handle), "trust_env": False,
        }
        return real_client(**kwargs)

    monkeypatch.setattr(suggestions.genai, "Client", client_factory)
    return state


@pytest.fixture
def api(gemini):
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        db.add_all([
            models.User(id=1, username="first", email="first@example.test", password_hash="unused"),
            models.User(id=2, username="second", email="second@example.test", password_hash="unused"),
        ])
        db.commit()

    def test_db():
        with Session(engine) as db:
            yield db

    app.dependency_overrides[get_db] = test_db
    try:
        with TestClient(app) as client:
            yield client, engine
    finally:
        app.dependency_overrides.pop(get_db)
        engine.dispose()


def auth(user_id=1):
    return {"Authorization": f"Bearer {create_access_token(str(user_id))}"}


def test_trends_use_all_grades_and_normalize_violation_exposure():
    rows = history_rows()
    history = suggestions.analyze_history(list(reversed(rows)))
    comparison = history["comparison"]
    assert history["hasSufficientHistory"] is True
    assert history["analysisStartDate"] == "2026-07-06T12:00:00"
    assert history["analysisEndDate"] == "2026-08-10T12:00:00"
    assert history["overall"]["tripDurationMinutes"] == 270
    assert history["overall"]["tripDistanceMiles"] == 75
    assert len(history["weekly"]) == 6
    assert history["weekly"][0]["weekStarting"] == "2026-07-06"
    assert comparison["earlier"]["reportCount"] == comparison["recent"]["reportCount"] == 3
    assert comparison["gradeChanges"] == {name: 12 for name in suggestions.GRADE_FIELDS}
    assert comparison["violationRateChanges"]["Proper Speed"] == {
        "countPerDrivingHour": -1, "violationMinutesPerDrivingHour": -1,
    }
    assert comparison["earlier"]["violationsByType"]["Proper Speed"]["durationSeconds"] == 180
    assert history["reports"] == [row.model_dump(mode="json", by_alias=True) for row in rows]


def test_weekly_averages_weight_trips_equally_and_skip_unobserved_weeks():
    rows = history_rows(3)
    rows[1].report_date = rows[0].report_date + timedelta(days=1)
    rows[1].trip_duration_minutes = 900
    history = suggestions.analyze_history(rows)
    assert [week["weekStarting"] for week in history["weekly"]] == ["2026-07-06", "2026-07-20"]
    assert history["weekly"][0]["averageGrades"]["overall_grade"] == 62


@pytest.mark.parametrize("kind", schemas.VIOLATION_TYPES)
def test_every_violation_type_and_null_road_are_preserved(kind):
    rows = history_rows()
    rows[0].violations[0].violation_type = kind
    rows[0].violations[0].road_name = None
    history = suggestions.analyze_history(rows)
    assert history["overall"]["violationsByType"][kind]["count"] >= 1
    assert history["reports"][0]["violations"][0]["roadName"] is None


def test_zero_duration_and_undated_reports_do_not_invent_temporal_data():
    rows = history_rows()
    for row in rows:
        row.trip_duration_minutes = 0
        row.trip_distance_miles = 0
    rows[-1].report_date = None
    history = suggestions.analyze_history(rows)
    assert history["reportsAnalyzed"] == 6
    assert history["datedReportCount"] == 5
    assert history["hasSufficientHistory"] is False
    assert history["overall"]["violationsByType"]["Proper Speed"]["countPerDrivingHour"] is None
    assert history["comparison"]["violationRateChanges"]["Proper Speed"]["violationMinutesPerDrivingHour"] is None
    assert len(history["reports"]) == 6


@pytest.mark.parametrize("count,span_days,sufficient", [(5, 28, False), (6, 27, False), (6, 28, True)])
def test_history_threshold(count, span_days, sufficient):
    rows = history_rows(count)
    for index, row in enumerate(rows):
        row.report_date = datetime(2026, 7, 1) + timedelta(days=span_days * index / (count - 1))
    assert suggestions.analyze_history(rows)["hasSufficientHistory"] is sufficient


def test_endpoint_and_prompt_use_only_token_users_complete_report_data(api, gemini):
    client, engine = api
    rows = [report(index) for index in range(6)]
    others = [report(index, user_id=2) for index in range(6)]
    for row in others:
        row.violations[0].road_name = "Other user's road"
    # Also defend against a violation with an inconsistent denormalized user ID.
    rows[0].violations.append(models.Violation(
        user_id=2, violation_type="Focused Driving", road_name="Other user's violation",
        start_time=rows[0].report_date, end_time=rows[0].report_date,
    ))
    seed(engine, rows + others)
    reports_response = client.get("/driving-reports?limit=100", headers=auth())
    response = client.get("/advanced-suggestion?userId=2", headers=auth())
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {
        "status": "ready",
        "message": "Your grades are steadily improving. Keep working on consistent speed control.",
        "reportsAnalyzed": 6,
        "analysisStartDate": "2026-07-06T12:00:00",
        "analysisEndDate": "2026-08-10T12:00:00",
    }
    request = gemini["requests"][0]
    payload = json.loads(request.content)
    history = json.loads(payload["contents"][0]["parts"][0]["text"])
    assert history["reports"] == list(reversed(reports_response.json()["reports"]))
    assert "Other user's" not in json.dumps(history)
    assert "Roosevelt Blvd" in json.dumps(history)
    assert "first@example.test" not in json.dumps(history)
    assert "userId" not in json.dumps(history)
    assert "Bearer" not in json.dumps(history)
    assert "gemini-3.5-flash-lite:generateContent" in str(request.url)
    assert payload["generationConfig"]["responseMimeType"] == "application/json"
    assert gemini["options"].timeout == 30000
    assert gemini["options"].retry_options.attempts == 1
    instruction = payload["systemInstruction"]["parts"][0]["text"]
    assert "Road names are optional context" in instruction
    assert "Treat every supplied grade and violation as accurate" in instruction


def test_only_latest_100_trips_are_analyzed_with_stable_ties(api, gemini):
    client, engine = api
    rows = [report(index, overall_grade=80, speed_grade=80, braking_grade=80,
                   acceleration_grade=80, turning_grade=80, focus_grade=80,
                   violations=[]) for index in range(102)]
    rows[0].report_date = rows[1].report_date = rows[2].report_date
    seed(engine, rows)
    response = client.get("/advanced-suggestion", headers=auth())
    assert response.status_code == 200
    assert response.json()["reportsAnalyzed"] == 100
    payload = json.loads(gemini["requests"][0].content)
    history = json.loads(payload["contents"][0]["parts"][0]["text"])
    assert [row["id"] for row in history["reports"]] == list(range(1002, 1102))


@pytest.mark.parametrize("count", [0, 1, 5])
def test_insufficient_history_returns_message_without_gemini_or_key(api, gemini, monkeypatch, count):
    client, engine = api
    monkeypatch.setattr(settings, "gemini_api_key", "")
    seed(engine, [report(index) for index in range(count)])
    response = client.get("/advanced-suggestion", headers=auth())
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "insufficient_history"
    assert body["reportsAnalyzed"] == count
    assert body["message"]
    assert (body["analysisStartDate"] is None) == (count == 0)
    assert gemini["requests"] == []


@pytest.mark.parametrize("credentials", ["missing", "invalid", "expired", "nonexistent"])
def test_authentication_rejects_bad_tokens_before_gemini(api, gemini, credentials):
    client, _ = api
    if credentials == "missing":
        headers = {}
    elif credentials == "invalid":
        headers = {"Authorization": "Bearer invalid"}
    elif credentials == "expired":
        token = jwt.encode(
            {"sub": "1", "exp": datetime.now(timezone.utc) - timedelta(minutes=1)},
            settings.jwt_secret_key, algorithm=settings.jwt_algorithm,
        )
        headers = {"Authorization": f"Bearer {token}"}
    else:
        headers = auth(999)
    response = client.get("/advanced-suggestion", headers=headers)
    assert response.status_code in (401, 403)
    assert gemini["requests"] == []


def test_missing_configuration_is_a_service_error_only_for_ready_history(api, gemini, monkeypatch):
    client, engine = api
    seed(engine, [report(index) for index in range(6)])
    monkeypatch.setattr(settings, "gemini_api_key", " ")
    response = client.get("/advanced-suggestion", headers=auth())
    assert response.status_code == 503
    assert response.json()["detail"] == "Driving feedback is not configured."
    assert gemini["requests"] == []


@pytest.mark.parametrize("provider_status,expected", [(400, 502), (401, 503), (403, 503), (404, 503), (429, 429), (500, 503), (503, 503), (504, 504)])
def test_provider_errors_are_mapped_without_leaking_details(api, gemini, provider_status, expected):
    client, engine = api
    seed(engine, [report(index) for index in range(6)])
    gemini["status"] = provider_status
    gemini["body"] = {"error": {"code": provider_status, "message": "private provider diagnostic"}}
    response = client.get("/advanced-suggestion", headers=auth())
    assert response.status_code == expected
    assert "private provider diagnostic" not in response.text
    assert response.headers["cache-control"] == "no-store"
    assert len(gemini["requests"]) == 1


@pytest.mark.parametrize("error,expected", [(httpx.ReadTimeout("timeout"), 504), (httpx.ConnectError("connection"), 503)])
def test_transport_failures(api, gemini, error, expected):
    client, engine = api
    seed(engine, [report(index) for index in range(6)])
    gemini["error"] = error
    assert client.get("/advanced-suggestion", headers=auth()).status_code == expected
    assert len(gemini["requests"]) == 1


@pytest.mark.parametrize("text", ["not json", "{}", '{"message": "   "}', '{"message": 3}', json.dumps({"message": "x" * 1201}), '{"message": "hello", "extra": "unexpected"}'])
def test_invalid_feedback_is_not_returned_to_frontend(api, gemini, text):
    client, engine = api
    seed(engine, [report(index) for index in range(6)])
    gemini["body"]["candidates"][0]["content"]["parts"][0]["text"] = text
    response = client.get("/advanced-suggestion", headers=auth())
    assert response.status_code == 502


@pytest.mark.parametrize("kind", ["blocked", "truncated", "empty"])
def test_blocked_truncated_and_empty_responses_are_rejected(api, gemini, kind):
    client, engine = api
    seed(engine, [report(index) for index in range(6)])
    if kind == "blocked":
        gemini["body"] = {"promptFeedback": {"blockReason": "SAFETY"}}
    elif kind == "truncated":
        gemini["body"]["candidates"][0]["finishReason"] = "MAX_TOKENS"
    else:
        gemini["body"]["candidates"][0]["content"]["parts"] = []
    assert client.get("/advanced-suggestion", headers=auth()).status_code == 502


def test_openapi_documents_authentication_and_single_message():
    schema = app.openapi()
    operation = schema["paths"]["/advanced-suggestion"]["get"]
    assert operation["security"] == [{"HTTPBearer": []}]
    assert {"200", "429", "502", "503", "504"} <= operation["responses"].keys()
    properties = schema["components"]["schemas"]["AdvancedSuggestionOut"]["properties"]
    assert set(properties) == {"status", "message", "reportsAnalyzed", "analysisStartDate", "analysisEndDate"}
