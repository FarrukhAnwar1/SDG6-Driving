"""Family mutations lock family -> users -> invitations, then commit once.

Authentication has already opened a MySQL REPEATABLE READ snapshot. Locking
reads must reload ORM objects and membership checks must use current reads.
No email or other external side effects belong in the retried transaction.
"""
from collections.abc import Callable
from typing import TypeVar

from fastapi import HTTPException, status
from sqlalchemy import delete, inspect, select
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from .. import models, schemas

T = TypeVar("T")
MAX_ATTEMPTS = 3
MYSQL_LOCK_ERRORS = {1205, 1213}  # lock wait timeout, deadlock victim


class MembershipChanged(Exception):
    """Retry with the new family after releasing locks on the previous one."""


def mutate_family(db: Session, action: Callable[[], T]) -> T:
    for _ in range(MAX_ATTEMPTS):
        try:
            result = action()
            db.commit()
            return result
        except MembershipChanged:
            db.rollback()
        except OperationalError as error:
            db.rollback()
            if not error.orig.args or error.orig.args[0] not in MYSQL_LOCK_ERRORS:
                raise
        except Exception:
            db.rollback()
            raise
    raise HTTPException(
        status.HTTP_503_SERVICE_UNAVAILABLE,
        "Your family is being updated. Please try again.",
        headers={"Retry-After": "1"},
    )


def lock_family(db: Session, family_id: int) -> models.DrivingFamily | None:
    return db.scalar(
        select(models.DrivingFamily)
        .where(models.DrivingFamily.id == family_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )


def lock_user(db: Session, user: models.User) -> models.User:
    # Identity remains available after rollback, even when attributes expire.
    user_id = inspect(user).identity[0]
    locked = db.scalar(
        select(models.User)
        .where(models.User.id == user_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if locked is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Account no longer exists.")
    return locked


def lock_membership(db: Session, user: models.User) -> models.DrivingFamily | None:
    # family_id is a hint until the user is locked and refreshed. If it changed
    # while waiting, release the old locks before trying the new family.
    family_id = user.family_id
    family = lock_family(db, family_id) if family_id is not None else None
    lock_user(db, user)
    if user.family_id != family_id:
        raise MembershipChanged
    return family


def revoke_invitations(db: Session, family_id: int, email: str) -> None:
    db.execute(
        delete(models.FamilyInvitation).where(
            models.FamilyInvitation.family_id == family_id,
            models.FamilyInvitation.email == schemas.normalize_email(email),
        )
    )


def delete_family(db: Session, family: models.DrivingFamily) -> None:
    # Callers hold the family lock and have cleared every member's family_id.
    # Explicit DELETEs use current data instead of ORM relationship lazy loads
    # that could miss invitations committed since authentication's snapshot.
    db.flush()
    db.execute(
        delete(models.FamilyInvitation).where(
            models.FamilyInvitation.family_id == family.id
        )
    )
    db.execute(delete(models.DrivingFamily).where(models.DrivingFamily.id == family.id))
