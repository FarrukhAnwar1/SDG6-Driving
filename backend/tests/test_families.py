"""Exercise the family API with real transactions and mocked email delivery.

By default this uses SQLite. FAMILY_TEST_MYSQL_URL can point at an EMPTY local
database named sdg6_family_test_* to also run the InnoDB concurrency tests.
Never use the application's deployed database for these destructive fixtures.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
import os
from threading import Barrier, Event
from unittest.mock import Mock

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pymysql
import pytest
from sqlalchemy import create_engine, event, inspect, select, text, update
from sqlalchemy.engine import make_url
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app import models, schemas
from app.config import settings
from app.database import Base
from app.dependencies import get_db
from app.main import app
from app.routers import families
from app.security import create_access_token, hash_invitation_code
from app.services.family_transactions import lock_membership, mutate_family


@pytest.fixture
def family_engine():
    mysql_url = os.environ.get("FAMILY_TEST_MYSQL_URL")
    if mysql_url:
        url = make_url(mysql_url)
        if (
            url.get_backend_name() != "mysql"
            or url.host not in {"localhost", "127.0.0.1", "::1"}
            or not (url.database or "").startswith("sdg6_family_test_")
        ):
            pytest.fail("FAMILY_TEST_MYSQL_URL must name an empty local sdg6_family_test_* database")
        engine = create_engine(url, isolation_level="REPEATABLE READ")

        @event.listens_for(engine, "connect")
        def limit_lock_wait(connection, _):
            with connection.cursor() as cursor:
                cursor.execute("SET SESSION innodb_lock_wait_timeout=5")

        if inspect(engine).get_table_names():
            engine.dispose()
            pytest.fail("The MySQL family test database must be empty")
    else:
        engine = create_engine(
            "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool,
        )

        @event.listens_for(engine, "connect")
        def enforce_foreign_keys(connection, _):
            connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    try:
        yield engine
    finally:
        if engine.dialect.name == "mysql":
            # The users/families FK cycle has an unnamed use_alter FK in ORM
            # metadata. Drop only these test tables with FK checks disabled.
            with engine.connect() as connection:
                connection.execute(text("SET FOREIGN_KEY_CHECKS=0"))
                try:
                    for table in reversed(Base.metadata.sorted_tables):
                        name = engine.dialect.identifier_preparer.format_table(table)
                        connection.execute(text(f"DROP TABLE {name}"))
                    connection.commit()
                finally:
                    connection.execute(text("SET FOREIGN_KEY_CHECKS=1"))
                    connection.commit()
        engine.dispose()


@pytest.fixture
def api(family_engine, monkeypatch):
    monkeypatch.setattr(settings, "jwt_secret_key", "family-api-test-signing-key-at-least-32-bytes")

    def test_db():
        with Session(family_engine, autoflush=False) as db:
            yield db

    monkeypatch.setitem(app.dependency_overrides, get_db, test_db)
    email = Mock()
    monkeypatch.setattr(families, "send_family_invitation_email", email)
    with Session(family_engine) as db:
        for user_id, name in [(1, "admin"), (2, "member"), (3, "outsider"), (4, "otheradmin")]:
            db.add(models.User(
                id=user_id, username=name, email=f"{name}@example.test", password_hash="unused",
                email_verified=True,
            ))
        db.commit()
    with TestClient(app, raise_server_exceptions=False) as client:
        yield client, email


def auth(user_id):
    return {"Authorization": f"Bearer {create_access_token(str(user_id))}"}


def create(client, user_id=1):
    response = client.post("/families", json={}, headers=auth(user_id))
    assert response.status_code == 201, response.text
    return response.json()["family"]["id"]


def invite(client, email_mock, email="member@example.test", admin=1):
    response = client.post(
        "/families/me/invitations", json={"email": email}, headers=auth(admin),
    )
    assert response.status_code == 204, response.text
    return email_mock.call_args.args[1]


def join(client, code, user_id=2):
    return client.post("/families/join", json={"code": code}, headers=auth(user_id))


def pending(engine):
    with Session(engine) as db:
        return list(db.scalars(select(models.FamilyInvitation.code_hash)))


def assert_error(response, status_code, code):
    assert response.status_code == status_code, response.text
    assert response.json()["detail"]["code"] == code


PROTECTED_ROUTES = [
    ("POST", "/families", {}),
    ("GET", "/families/me", None),
    ("POST", "/families/join", {"code": "test-code"}),
    ("POST", "/families/leave", {}),
    ("POST", "/families/me/invitations", {"email": "member@example.test"}),
    ("DELETE", "/families/me/members/2", None),
]


@pytest.mark.parametrize("method,path,body", PROTECTED_ROUTES)
@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer invalid-token"}])
def test_every_family_endpoint_requires_authentication(api, method, path, body, headers):
    client, email = api
    response = client.request(method, path, json=body, headers=headers)
    assert response.status_code in {401, 403}
    email.assert_not_called()


def test_create_and_read_membership_and_reject_second_family(api, family_engine):
    client, _ = api
    assert client.get("/families/me", headers=auth(1)).json() == {"family": None}
    family_id = create(client)
    family = client.get("/families/me", headers=auth(1)).json()["family"]
    assert family["adminUserId"] == 1
    assert family["members"] == [{
        "userId": 1, "username": "admin", "driveCount": 0,
        "averageGrades": None, "latestDrive": None,
        "totalDrivingMinutes": 0, "totalDistanceMiles": 0,
    }]
    assert_error(client.post("/families", json={}, headers=auth(1)), 409, "already_in_family")
    with Session(family_engine) as db:
        assert db.get(models.User, 1).family_id == family_id
        assert len(list(db.scalars(select(models.DrivingFamily)))) == 1


def test_invitation_email_is_normalized_and_only_hash_is_stored(api, family_engine):
    client, email = api
    family_id = create(client)
    code = invite(client, email, "  Member@Example.TEST ")
    email.assert_called_once_with("member@example.test", code, "admin")
    assert len(code) >= 32
    with Session(family_engine) as db:
        invitation = db.scalar(select(models.FamilyInvitation))
        assert invitation.family_id == family_id
        assert invitation.email == "member@example.test"
        assert invitation.invited_by_user_id == 1
        assert invitation.code_hash == hash_invitation_code(code)
        assert invitation.code_hash != code


def test_wrong_email_preserves_invitation_and_correct_email_can_join(api, family_engine):
    client, email = api
    family_id = create(client)
    code = invite(client, email)
    assert_error(join(client, code, 3), 403, "invitation_email_mismatch")
    assert pending(family_engine) == [hash_invitation_code(code)]
    with Session(family_engine) as db:
        assert db.get(models.User, 3).family_id is None
        db.get(models.User, 2).email = "Member@Example.TEST"
        db.commit()
    response = join(client, f"  {code}  ")
    assert response.status_code == 200, response.text
    assert response.json()["family"]["id"] == family_id
    assert {m["userId"] for m in response.json()["family"]["members"]} == {1, 2}
    assert pending(family_engine) == []


def test_join_consumes_sibling_codes_without_revoking_other_recipients_or_families(api, family_engine):
    client, email = api
    create(client)
    first = invite(client, email)
    sibling = invite(client, email)
    unrelated = invite(client, email, "outsider@example.test")
    create(client, 4)
    other_family_code = invite(client, email, admin=4)
    assert join(client, first).status_code == 200
    assert set(pending(family_engine)) == {
        hash_invitation_code(unrelated), hash_invitation_code(other_family_code),
    }
    assert hash_invitation_code(sibling) not in pending(family_engine)
    assert_error(join(client, other_family_code), 409, "already_in_family")
    assert hash_invitation_code(other_family_code) in pending(family_engine)


@pytest.mark.parametrize("exit_action", ["leave", "remove"])
def test_old_codes_cannot_bypass_leaving_or_removal(api, family_engine, exit_action):
    client, email = api
    create(client)
    first = invite(client, email)
    old_unused = invite(client, email)
    assert join(client, first).status_code == 200
    # Also revoke invitations sent while the recipient was already a member.
    while_member = invite(client, email)
    if exit_action == "leave":
        response = client.post("/families/leave", json={}, headers=auth(2))
    else:
        response = client.delete("/families/me/members/2", headers=auth(1))
    assert response.status_code == 204, response.text
    assert client.get("/families/me", headers=auth(2)).json() == {"family": None}
    assert pending(family_engine) == []
    for code in (first, old_unused, while_member):
        assert_error(join(client, code), 400, "invalid_invitation")
    fresh = invite(client, email)
    assert join(client, fresh).status_code == 200


def test_only_admin_can_invite_or_remove_and_cannot_remove_self_or_other_family(api, family_engine):
    client, email = api
    create(client)
    code = invite(client, email)
    assert join(client, code).status_code == 200
    email.reset_mock()
    assert_error(client.post(
        "/families/me/invitations", json={"email": "outsider@example.test"}, headers=auth(2),
    ), 403, "admin_required")
    assert_error(client.delete("/families/me/members/1", headers=auth(2)), 403, "admin_required")
    assert client.delete("/families/me/members/1", headers=auth(1)).status_code == 400
    create(client, 4)
    assert client.delete("/families/me/members/4", headers=auth(1)).status_code == 404
    email.assert_not_called()
    assert pending(family_engine) == []
    # Outsiders cannot read either family's summaries.
    assert client.get("/families/me", headers=auth(3)).json() == {"family": None}
    other = client.get("/families/me", headers=auth(4)).json()["family"]
    assert [m["userId"] for m in other["members"]] == [4]


@pytest.mark.parametrize("method,path,body", PROTECTED_ROUTES[3:])
def test_no_family_rejects_member_actions(api, method, path, body):
    client, email = api
    assert_error(client.request(method, path, json=body, headers=auth(3)), 403, "not_in_family")
    email.assert_not_called()


def test_admin_can_only_leave_last_and_deletion_invalidates_pending_codes(api, family_engine):
    client, email = api
    family_id = create(client)
    assert join(client, invite(client, email)).status_code == 200
    code = invite(client, email, "outsider@example.test")
    assert_error(client.post("/families/leave", json={}, headers=auth(1)), 409, "admin_cannot_leave")
    assert client.post("/families/leave", json={}, headers=auth(2)).status_code == 204
    assert client.post("/families/leave", json={}, headers=auth(1)).status_code == 204
    with Session(family_engine) as db:
        assert db.get(models.DrivingFamily, family_id) is None
        assert db.get(models.User, 1).family_id is None
        assert db.get(models.User, 2) is not None
    assert pending(family_engine) == []
    assert_error(join(client, code, 3), 400, "invalid_invitation")


def test_member_account_deletion_revokes_pending_codes(api, family_engine):
    client, email = api
    create(client)
    assert join(client, invite(client, email)).status_code == 200
    invite(client, email)
    assert client.delete("/users/me", headers=auth(2)).status_code == 204
    assert pending(family_engine) == []


def test_admin_account_deletion_frees_members_and_preserves_their_reports(api, family_engine):
    client, email = api
    family_id = create(client)
    assert join(client, invite(client, email)).status_code == 200
    invite(client, email, "outsider@example.test")
    with Session(family_engine) as db:
        db.add(models.DrivingReport(
            user_id=2, overall_grade=80, speed_grade=80, braking_grade=80,
            acceleration_grade=80, turning_grade=80, focus_grade=80,
            trip_duration_minutes=10, trip_distance_miles=5,
        ))
        db.commit()
    response = client.delete("/users/me", headers=auth(1))
    assert response.status_code == 204, response.text
    assert pending(family_engine) == []
    with Session(family_engine) as db:
        assert db.get(models.DrivingFamily, family_id) is None
        assert db.get(models.User, 1) is None
        assert db.get(models.User, 2).family_id is None
        assert db.scalar(select(models.DrivingReport.user_id)) == 2


def test_family_statistics_use_all_categories_ignore_null_focus_and_order_latest(api, family_engine):
    client, email = api
    create(client)
    assert join(client, invite(client, email)).status_code == 200
    names = ["overall_grade", "speed_grade", "braking_grade", "acceleration_grade", "turning_grade"]
    dates = [datetime(2026, 1, 3), datetime(2026, 1, 2), datetime(2026, 1, 3)]
    with Session(family_engine) as db:
        for report_id, base in enumerate([50, 70, 90], 1):
            db.add(models.DrivingReport(
                id=report_id, user_id=2, report_date=dates[report_id - 1],
                driving_mode="navigation" if report_id == 2 else "regular",
                **{name: base + i for i, name in enumerate(names)},
                focus_grade=None if report_id == 2 else base + 5,
                trip_duration_minutes=report_id * 10, trip_distance_miles=report_id * 5,
            ))
        # An undated report counts toward averages/totals but cannot beat dated trips.
        undated = models.DrivingReport(
            id=4, user_id=2, **{name: 30 for name in names}, focus_grade=45,
            trip_duration_minutes=2.5, trip_distance_miles=1.25,
        )
        db.add(undated)
        db.flush()
        db.execute(update(models.DrivingReport).where(models.DrivingReport.id == 4).values(report_date=None))
        db.commit()
    response = client.get("/families/me", headers=auth(1))
    assert response.status_code == 200, response.text
    admin, member = response.json()["family"]["members"]
    assert admin["driveCount"] == 0 and admin["latestDrive"] is None
    assert member["driveCount"] == 4
    assert member["averageGrades"] == {
        "overallGrade": 60, "speedGrade": 60.75, "brakingGrade": 61.5,
        "accelerationGrade": 62.25, "turningGrade": 63, "focusGrade": 65,
    }
    assert member["latestDrive"] == {
        "overallGrade": 90, "speedGrade": 91, "brakingGrade": 92,
        "accelerationGrade": 93, "turningGrade": 94, "focusGrade": 95,
        "reportDate": "2026-01-03T00:00:00",
    }
    assert member["totalDrivingMinutes"] == 62.5
    assert member["totalDistanceMiles"] == 31.25


def test_statistics_are_not_limited_to_a_report_history_page(api, family_engine):
    client, _ = api
    create(client)
    with Session(family_engine) as db:
        for i in range(105):
            db.add(models.DrivingReport(
                user_id=1, report_date=datetime(2026, 1, 1) + timedelta(minutes=i),
                overall_grade=80, speed_grade=81, braking_grade=82,
                acceleration_grade=83, turning_grade=84, focus_grade=85,
                trip_duration_minutes=1, trip_distance_miles=2,
            ))
        db.commit()
    member = client.get("/families/me", headers=auth(1)).json()["family"]["members"][0]
    assert member["driveCount"] == 105
    assert member["totalDrivingMinutes"] == 105
    assert member["totalDistanceMiles"] == 210


def test_email_failure_discards_only_the_failed_invitation_and_can_retry(api, family_engine):
    client, email = api
    create(client)
    first = invite(client, email)
    email.side_effect = RuntimeError("Simulated email outage")
    response = client.post(
        "/families/me/invitations", json={"email": "outsider@example.test"}, headers=auth(1),
    )
    assert response.status_code == 502
    assert pending(family_engine) == [hash_invitation_code(first)]
    email.side_effect = None
    assert invite(client, email, "outsider@example.test")


def fail_updates(engine, *, code, failures):
    calls = []

    def fail(_conn, _cursor, statement, _parameters, _context, _executemany):
        if statement.upper().startswith("UPDATE USERS SET FAMILY_ID"):
            calls.append(statement)
            if len(calls) <= failures:
                raise OperationalError(statement, {}, pymysql.err.OperationalError(code, "Injected DB failure"))

    event.listen(engine, "before_cursor_execute", fail)
    return calls, fail


@pytest.mark.parametrize("code", [1205, 1213])
def test_join_retries_lock_failures_and_commits_membership_and_revocation_once(api, family_engine, code):
    client, email = api
    create(client)
    join_code = invite(client, email)
    invite(client, email)
    calls, handler = fail_updates(family_engine, code=code, failures=1)
    try:
        response = join(client, join_code)
    finally:
        event.remove(family_engine, "before_cursor_execute", handler)
    assert response.status_code == 200, response.text
    assert len(calls) == 2
    assert pending(family_engine) == []


@pytest.mark.parametrize("code,status_code,attempts", [(1213, 503, 3), (1054, 500, 1)])
def test_failed_join_rolls_back_all_revocations_and_membership(api, family_engine, code, status_code, attempts):
    client, email = api
    create(client)
    join_code = invite(client, email)
    sibling = invite(client, email)
    calls, handler = fail_updates(family_engine, code=code, failures=99)
    try:
        response = join(client, join_code)
    finally:
        event.remove(family_engine, "before_cursor_execute", handler)
    assert response.status_code == status_code, response.text
    assert len(calls) == attempts
    if status_code == 503:
        assert response.headers["Retry-After"] == "1"
    assert set(pending(family_engine)) == {hash_invitation_code(join_code), hash_invitation_code(sibling)}
    with Session(family_engine) as db:
        assert db.get(models.User, 2).family_id is None
    assert join(client, join_code).status_code == 200


def test_invitation_transaction_retry_sends_only_one_email(api, family_engine):
    client, email = api
    create(client)
    attempts = []

    def fail_once(_conn, _cursor, statement, _parameters, _context, _executemany):
        if statement.upper().startswith("INSERT INTO FAMILY_INVITATIONS"):
            attempts.append(statement)
            if len(attempts) == 1:
                raise OperationalError(statement, {}, pymysql.err.OperationalError(1213, "Injected deadlock"))

    event.listen(family_engine, "before_cursor_execute", fail_once)
    try:
        code = invite(client, email)
    finally:
        event.remove(family_engine, "before_cursor_execute", fail_once)
    assert len(attempts) == 2
    email.assert_called_once()
    assert pending(family_engine) == [hash_invitation_code(code)]


@pytest.mark.parametrize("exit_action", ["leave", "remove"])
def test_leave_and_remove_retry_deadlocks_without_losing_invitation_revocation(api, family_engine, exit_action):
    client, email = api
    create(client)
    assert join(client, invite(client, email)).status_code == 200
    invite(client, email)
    calls, handler = fail_updates(family_engine, code=1213, failures=1)
    try:
        if exit_action == "leave":
            response = client.post("/families/leave", json={}, headers=auth(2))
        else:
            response = client.delete("/families/me/members/2", headers=auth(1))
    finally:
        event.remove(family_engine, "before_cursor_execute", handler)
    assert response.status_code == 204, response.text
    assert len(calls) == 2
    assert pending(family_engine) == []
    assert client.get("/families/me", headers=auth(2)).json() == {"family": None}


def test_membership_change_releases_old_locks_and_retries_with_current_family(api, family_engine):
    client, _ = api
    first_family = create(client)
    # Keep an authenticated user's ORM state stale while another session moves
    # them. The first locked refresh must detect this and restart the transaction.
    with Session(family_engine) as db:
        user = db.get(models.User, 2)
        with Session(family_engine) as writer:
            writer.execute(update(models.User).where(models.User.id == 2).values(family_id=first_family))
            writer.commit()
        attempts = []

        def load():
            attempts.append(True)
            return lock_membership(db, user).id

        assert mutate_family(db, load) == first_family
        assert len(attempts) == 2


@pytest.fixture
def mysql_engine(family_engine):
    if family_engine.dialect.name != "mysql":
        pytest.skip("Set FAMILY_TEST_MYSQL_URL to an empty local test database for InnoDB concurrency tests")
    return family_engine


def run_as(engine, user_id, action, ready=None, role=None):
    with engine.connect() as connection, Session(connection, autoflush=False) as db:
        connection.info["family_test_role"] = role
        try:
            user = db.get(models.User, user_id)
            if ready is not None:
                ready.wait(timeout=10)
            try:
                return action(user, db)
            except HTTPException as error:
                return error.status_code
        finally:
            connection.info.pop("family_test_role", None)


def test_mysql_admin_leave_sees_join_committed_after_authentication(api, mysql_engine):
    client, email = api
    family_id = create(client)
    code = invite(client, email)
    with Session(mysql_engine, autoflush=False) as db:
        admin = db.get(models.User, 1)  # establishes the old REPEATABLE READ snapshot
        assert join(client, code).status_code == 200
        with pytest.raises(HTTPException) as error:
            families.leave_family(admin, db)
        assert error.value.status_code == 409
        assert error.value.detail["code"] == "admin_cannot_leave"
    with Session(mysql_engine) as db:
        assert db.get(models.DrivingFamily, family_id) is not None
        assert db.get(models.User, 2).family_id == family_id


def test_mysql_remove_and_leave_do_not_take_locks_in_opposite_order(api, mysql_engine):
    client, email = api
    create(client)
    assert join(client, invite(client, email)).status_code == 200
    leave_reached_family = Event()
    removal_has_family = Event()

    def before(connection, _cursor, statement, _params, _context, _many):
        if (
            connection.info.get("family_test_role") == "leave"
            and "FROM driving_families" in statement
            and "FOR UPDATE" in statement
        ):
            leave_reached_family.set()

    def after(connection, _cursor, statement, _params, _context, _many):
        if (
            connection.info.get("family_test_role") == "remove"
            and "FROM driving_families" in statement
            and "FOR UPDATE" in statement
        ):
            removal_has_family.set()
            assert leave_reached_family.wait(10), "leave did not reach family locking"

    event.listen(mysql_engine, "before_cursor_execute", before)
    event.listen(mysql_engine, "after_cursor_execute", after)
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            removal = pool.submit(
                run_as, mysql_engine, 1,
                lambda user, db: families.remove_family_member(2, user, db) or 204,
                role="remove",
            )
            assert removal_has_family.wait(10)
            leaving = pool.submit(
                run_as, mysql_engine, 2,
                lambda user, db: families.leave_family(user, db) or 204,
                role="leave",
            )
            assert removal.result(timeout=20) == 204
            assert leaving.result(timeout=20) == 403
    finally:
        event.remove(mysql_engine, "before_cursor_execute", before)
        event.remove(mysql_engine, "after_cursor_execute", after)
    assert client.get("/families/me", headers=auth(2)).json() == {"family": None}


def test_mysql_join_waiting_on_last_admin_leave_rejects_deleted_family(api, mysql_engine):
    client, email = api
    create(client)
    code = invite(client, email)
    admin_checked_members = Event()
    join_reached_family = Event()

    def before(connection, _cursor, statement, _params, _context, _many):
        if (
            connection.info.get("family_test_role") == "join"
            and "FROM driving_families" in statement
            and "FOR UPDATE" in statement
        ):
            join_reached_family.set()

    def after(connection, _cursor, statement, _params, _context, _many):
        if (
            connection.info.get("family_test_role") == "leave"
            and "FROM users" in statement
            and "LIMIT" in statement
            and "FOR UPDATE" in statement
        ):
            admin_checked_members.set()
            assert join_reached_family.wait(10), "join did not reach family locking"

    event.listen(mysql_engine, "before_cursor_execute", before)
    event.listen(mysql_engine, "after_cursor_execute", after)
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            leaving = pool.submit(
                run_as, mysql_engine, 1,
                lambda user, db: families.leave_family(user, db) or 204,
                role="leave",
            )
            assert admin_checked_members.wait(10)

            def redeem(user, db):
                families.join_family(schemas.FamilyJoinRequest(code=code), user, db)
                return 200

            joining = pool.submit(run_as, mysql_engine, 2, redeem, role="join")
            assert leaving.result(timeout=20) == 204
            assert joining.result(timeout=20) == 400
    finally:
        event.remove(mysql_engine, "before_cursor_execute", before)
        event.remove(mysql_engine, "after_cursor_execute", after)
    assert pending(mysql_engine) == []
    assert client.get("/families/me", headers=auth(2)).json() == {"family": None}


@pytest.mark.parametrize("competing_action", ["redeem", "create", "other_family"])
def test_mysql_concurrent_join_cannot_overwrite_another_membership(api, mysql_engine, competing_action):
    client, email = api
    create(client)
    code = invite(client, email)
    other_code = code
    if competing_action == "other_family":
        create(client, 4)
        other_code = invite(client, email, admin=4)
    ready = Barrier(2)

    def redeem(user, db):
        families.join_family(schemas.FamilyJoinRequest(code=code), user, db)
        return 200

    def compete(user, db):
        if competing_action == "create":
            families.create_family(user, db)
            return 201
        families.join_family(schemas.FamilyJoinRequest(code=other_code), user, db)
        return 200

    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(run_as, mysql_engine, 2, redeem, ready)
        second = pool.submit(run_as, mysql_engine, 2, compete, ready)
        statuses = [first.result(timeout=20), second.result(timeout=20)]
    assert statuses.count(409) == 1
    assert sum(code in {200, 201} for code in statuses) == 1
    with Session(mysql_engine) as db:
        member = db.get(models.User, 2)
        family = db.get(models.DrivingFamily, member.family_id)
        assert family is not None
        for family in db.scalars(select(models.DrivingFamily)):
            assert db.get(models.User, family.admin_user_id).family_id == family.id
