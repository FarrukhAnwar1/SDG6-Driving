"""Exercise the Driving Family tables and schemas against SQLite with FKs enforced."""

from fastapi.testclient import TestClient
from pydantic import ValidationError
import pytest
from sqlalchemy import create_engine, event, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app import models, schemas
from app.config import settings
from app.database import Base
from app.dependencies import get_db
from app.main import app
from app.security import create_access_token


@pytest.fixture
def engine():
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool,
    )

    # SQLite ignores foreign keys unless asked, which would let a bad delete
    # order pass here and then fail against MySQL
    @event.listens_for(engine, "connect")
    def enforce_foreign_keys(dbapi_connection, _):
        dbapi_connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    yield engine
    engine.dispose()


@pytest.fixture
def api(engine, monkeypatch):
    monkeypatch.setattr(settings, "jwt_secret_key", "family-test-signing-key-at-least-32-bytes")

    def test_db():
        with Session(engine) as db:
            yield db

    app.dependency_overrides[get_db] = test_db
    try:
        with TestClient(app) as client:
            yield client
    finally:
        app.dependency_overrides.pop(get_db)


def user(user_id, name):
    return models.User(
        id=user_id, username=name, email=f"{name}@example.test", password_hash="unused",
    )


def seed_family(engine):
    """Admin 1 with member 2 and one pending invitation; user 3 has no family."""
    with Session(engine) as db:
        admin, member, outsider = user(1, "admin"), user(2, "member"), user(3, "outsider")
        family = models.DrivingFamily(admin=admin)
        admin.family = family
        member.family = family
        family.invitations.append(models.FamilyInvitation(
            email="invitee@example.test", invited_by=admin, code_hash="a" * 64,
        ))
        db.add_all([admin, member, outsider, family])
        db.commit()
        return family.id


def count(db, model):
    return db.scalar(select(func.count()).select_from(model))


def auth(user_id):
    return {"Authorization": f"Bearer {create_access_token(str(user_id))}"}


def test_new_user_has_no_family(engine):
    with Session(engine) as db:
        db.add(user(1, "solo"))
        db.commit()
        assert db.get(models.User, 1).family_id is None


def test_family_and_admin_membership_are_created_in_one_commit(engine):
    family_id = seed_family(engine)
    with Session(engine) as db:
        family = db.get(models.DrivingFamily, family_id)
        assert family.admin_user_id == 1
        assert family.created_at is not None
        assert {member.id for member in family.members} == {1, 2}
        assert db.get(models.User, 1).administered_family is family
        assert db.get(models.User, 3).family_id is None


def test_a_user_cannot_administer_two_families(engine):
    seed_family(engine)
    with Session(engine) as db:
        db.add(models.DrivingFamily(admin_user_id=1))
        with pytest.raises(IntegrityError):
            db.commit()


def test_invitation_code_hashes_are_unique(engine):
    family_id = seed_family(engine)
    with Session(engine) as db:
        db.add(models.FamilyInvitation(
            family_id=family_id, email="other@example.test",
            invited_by_user_id=1, code_hash="a" * 64,
        ))
        with pytest.raises(IntegrityError):
            db.commit()


def test_admin_account_deletion_removes_family_and_frees_members(engine, api):
    seed_family(engine)
    response = api.delete("/users/me", headers=auth(1))
    assert response.status_code == 204

    with Session(engine) as db:
        assert count(db, models.DrivingFamily) == 0
        assert count(db, models.FamilyInvitation) == 0
        assert db.get(models.User, 1) is None
        assert db.get(models.User, 2).family_id is None
        assert db.get(models.User, 3) is not None


def test_member_account_deletion_leaves_family_intact(engine, api):
    family_id = seed_family(engine)
    response = api.delete("/users/me", headers=auth(2))
    assert response.status_code == 204

    with Session(engine) as db:
        family = db.get(models.DrivingFamily, family_id)
        assert [member.id for member in family.members] == [1]
        assert count(db, models.FamilyInvitation) == 1


def test_deleting_a_family_frees_every_member(engine):
    family_id = seed_family(engine)
    with Session(engine) as db:
        db.delete(db.get(models.DrivingFamily, family_id))
        db.commit()
        assert db.get(models.User, 1).family_id is None
        assert db.get(models.User, 2).family_id is None
        assert count(db, models.FamilyInvitation) == 0


def test_invitation_email_is_normalized():
    invitation = schemas.FamilyInvitationCreate(email="  Sam@Example.COM ")
    assert invitation.email == "sam@example.com"
    assert schemas.normalize_email(" Sam@Example.COM") == invitation.email


@pytest.mark.parametrize("email", ["", "sam", "sam@example", "sam smith@example.com", "a@b@c.com"])
def test_malformed_invitation_email_is_rejected(email):
    with pytest.raises(ValidationError):
        schemas.FamilyInvitationCreate(email=email)


def test_join_code_is_trimmed_but_keeps_case_and_punctuation():
    assert schemas.FamilyJoinRequest(code="  AbC-123_x.  ").code == "AbC-123_x."


@pytest.mark.parametrize("code", ["", "   ", "abc def", "abc\tdef"])
def test_blank_or_split_join_code_is_rejected(code):
    with pytest.raises(ValidationError):
        schemas.FamilyJoinRequest(code=code)


def test_family_response_uses_camel_case_and_null_family():
    assert schemas.FamilyMeOut().model_dump(by_alias=True) == {"family": None}

    body = schemas.FamilyMeOut(family=schemas.FamilyOut(
        id=7,
        admin_user_id=1,
        members=[schemas.FamilyMemberOut(
            user_id=2, username="Sam", drive_count=0,
            total_driving_minutes=0, total_distance_miles=0,
        )],
    )).model_dump(by_alias=True)
    assert body == {"family": {
        "id": 7,
        "adminUserId": 1,
        "members": [{
            "userId": 2, "username": "Sam", "driveCount": 0,
            "averageGrades": None, "latestDrive": None,
            "totalDrivingMinutes": 0, "totalDistanceMiles": 0,
        }],
    }}
