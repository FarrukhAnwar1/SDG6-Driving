# Regression tests for authentication, password limits, and duplicate report prevention.

"""Regression coverage for authentication, password limits, and upload retries."""
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock
from uuid import uuid4

import jwt
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app import models, schemas
from app.config import settings
from app.database import Base
from app.dependencies import get_db, get_pg_db
from app.main import app
from app.routers import driving_reports, users
from app.security import create_access_token, create_verification_token, hash_password, verify_password
from app.services import driving_reports as reports_service


@pytest.fixture(scope="module")
def password_hash():
    return hash_password("correct-password")


@pytest.fixture
def api(monkeypatch, password_hash):
    monkeypatch.setattr(settings, "jwt_secret_key", "mvp-test-signing-key-at-least-32-bytes")
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool,
    )

    @event.listens_for(engine, "connect")
    def foreign_keys(connection, _):
        connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    with Session(engine) as db:
        for user_id in (1, 2, 3):
            db.add(models.User(
                id=user_id, username=f"user{user_id}", email=f"user{user_id}@example.test",
                password_hash=password_hash, email_verified=user_id != 2,
            ))
        db.commit()

    def test_db():
        with Session(engine) as db:
            yield db

    monkeypatch.setitem(app.dependency_overrides, get_db, test_db)
    monkeypatch.setitem(app.dependency_overrides, get_pg_db, test_db)
    names = Mock(side_effect=lambda db, points: [None] * len(points))
    monkeypatch.setattr(driving_reports, "resolve_road_names", names)
    monkeypatch.setattr(users, "send_verification_email", Mock())
    with TestClient(app, raise_server_exceptions=False) as client:
        yield client, engine, names
    engine.dispose()


def auth(user_id=1):
    return {"Authorization": f"Bearer {create_access_token(str(user_id))}"}


def report(**overrides):
    result = {
        "clientTripId": str(uuid4()),
        "startedAt": "2026-10-18T10:00:00Z", "endedAt": "2026-10-18T10:10:00Z",
        "tripDistanceMiles": 2, "overallGrade": 90, "speedGrade": 90, "focusGrade": 90,
        "violations": [{
            "violationType": "Proper Speed", "startTime": "2026-10-18T10:02:00Z",
            "endTime": "2026-10-18T10:02:10Z", "latitude": 40, "longitude": -75,
        }],
    }
    result.update(overrides)
    return result


@pytest.mark.parametrize("path", ["/me", "/families/me", "/driving-reports", "/advanced-suggestion"])
def test_verification_tokens_cannot_read_protected_data(api, path):
    client, _, _ = api
    token = create_verification_token(1)
    assert client.get(path, headers={"Authorization": f"Bearer {token}"}).status_code == 401


def test_verification_tokens_cannot_mutate_accounts(api):
    client, _, _ = api
    headers = {"Authorization": f"Bearer {create_verification_token(2)}"}
    assert client.post("/families", headers=headers).status_code == 401
    assert client.delete("/users/me", headers=headers).status_code == 401


def test_unverified_accounts_and_old_sessions_are_rejected(api):
    client, _, _ = api
    assert client.get("/me", headers=auth(2)).status_code == 401
    legacy = jwt.encode(
        {"sub": "1", "exp": datetime.now(timezone.utc) + timedelta(hours=1)},
        settings.jwt_secret_key, algorithm=settings.jwt_algorithm,
    )
    assert client.get("/me", headers={"Authorization": f"Bearer {legacy}"}).status_code == 401


def test_fresh_login_issues_an_access_token(api):
    client, _, _ = api
    response = client.post("/login", json={"email": "user1@example.test", "password": "correct-password"})
    assert response.status_code == 200
    token = response.json()["access_token"]
    payload = jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
    assert payload["purpose"] == "access"
    assert client.get("/me", headers={"Authorization": f"Bearer {token}"}).json()["id"] == 1


def test_email_verification_still_works(api):
    client, engine, _ = api
    token = create_verification_token(2)
    with Session(engine) as db:
        db.get(models.User, 2).verification_token = token
        db.commit()
    assert client.get("/verify-email", params={"token": token}).status_code == 200
    assert client.get("/me", headers=auth(2)).status_code == 200


def test_user_directory_is_removed_for_every_caller(api):
    client, _, _ = api
    assert client.get("/users").status_code == 405
    assert client.get("/users", headers=auth()).status_code == 405
    assert "get" not in app.openapi()["paths"]["/users"]


@pytest.mark.parametrize("password", ["x" * 73, "é" * 40])
@pytest.mark.parametrize("path,field,extra", [
    ("/users", "password", {"username": "newuser", "email": "new@example.test"}),
    ("/login", "password", {"email": "user1@example.test"}),
    ("/reset-password", "new_password", {"email": "user1@example.test", "code": "123456"}),
    ("/change-password", "new_password", {"current_password": "correct-password"}),
    ("/change-password", "current_password", {"new_password": "replacement-password"}),
])
def test_oversized_passwords_are_validation_errors(api, password, path, field, extra):
    client, _, _ = api
    response = client.post(path, headers=auth(), json={**extra, field: password})
    assert response.status_code == 422
    assert "72 UTF-8 bytes" in response.text


@pytest.mark.parametrize("password", ["x" * 72, "é" * 36])
def test_password_byte_boundary_preserves_existing_bcrypt_format(password):
    hashed = hash_password(password)
    assert hashed.startswith("$2")
    assert verify_password(password, hashed)
    assert not verify_password("x" * 73, hashed)


def test_retry_returns_same_report_without_duplicate_violations_or_road_lookup(api):
    client, engine, names = api
    payload = report()
    first = client.post("/driving-reports", headers=auth(), json=payload)
    second = client.post("/driving-reports", headers=auth(), json=payload)
    assert first.status_code == second.status_code == 201
    assert first.json() == second.json()
    assert names.call_count == 1
    with Session(engine) as db:
        assert db.scalar(select(func.count()).select_from(models.DrivingReport)) == 1
        assert db.scalar(select(func.count()).select_from(models.Violation)) == 1


def test_reused_id_with_changed_payload_is_rejected(api):
    client, _, _ = api
    payload = report()
    assert client.post("/driving-reports", headers=auth(), json=payload).status_code == 201
    response = client.post("/driving-reports", headers=auth(), json={**payload, "speedGrade": 50})
    assert response.status_code == 409


def test_trip_ids_are_scoped_to_the_authenticated_account(api):
    client, engine, _ = api
    payload = report()
    first = client.post("/driving-reports", headers=auth(1), json=payload)
    second = client.post("/driving-reports", headers=auth(3), json=payload)
    assert first.status_code == second.status_code == 201
    assert first.json()["id"] != second.json()["id"]
    with Session(engine) as db:
        assert db.scalar(select(func.count()).select_from(models.DrivingReport)) == 2


def test_legacy_payloads_without_ids_are_also_retry_safe(api):
    client, _, _ = api
    payload = report()
    del payload["clientTripId"]
    first = client.post("/driving-reports", headers=auth(), json=payload)
    second = client.post("/driving-reports", headers=auth(), json=payload)
    assert first.status_code == second.status_code == 201
    assert first.json()["id"] == second.json()["id"]


def test_unique_constraint_recovers_a_retry_that_passed_the_initial_read(api, monkeypatch):
    client, engine, _ = api
    payload = report()
    saved = client.post("/driving-reports", headers=auth(), json=payload).json()
    find_existing = reports_service.find_existing_report
    calls = 0

    def concurrent_read(db, user_id, body):
        nonlocal calls
        calls += 1
        return None if calls == 1 else find_existing(db, user_id, body)

    monkeypatch.setattr(reports_service, "find_existing_report", concurrent_read)
    with Session(engine) as db:
        result = reports_service.write_driving_report(
            db, 1, schemas.DrivingReportCreate.model_validate(payload), [None],
        )
        assert result.id == saved["id"]
        assert calls == 2
        assert db.scalar(select(func.count()).select_from(models.Violation)) == 1


def test_unrelated_integrity_errors_are_not_hidden(api):
    _, engine, _ = api
    with Session(engine) as db, pytest.raises(IntegrityError):
        reports_service.write_driving_report(
            db, 999, schemas.DrivingReportCreate.model_validate(report()), [None],
        )
