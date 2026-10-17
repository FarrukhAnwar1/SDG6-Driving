from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select, update
from .. import models, schemas
from ..dependencies import CurrentUser, DbSession
from ..security import hash_password, create_verification_token
from ..email import send_verification_email
from ..services.family_transactions import (
    delete_family,
    lock_membership,
    mutate_family,
    revoke_invitations,
)

router = APIRouter(tags=["users"])

@router.get("/users", response_model=schemas.Users)
def get_users(db: DbSession):
    rows = db.scalars(select(models.User)).all()
    return schemas.Users(users=rows)

@router.post(
    "/users", response_model=schemas.UserOut, status_code=status.HTTP_201_CREATED
)
def add_user(user: schemas.UserCreate, db: DbSession):
    # username and email are unique in the table, so reject duplicates with a clear 409
    existing = db.scalar(
        select(models.User).where(
            (models.User.username == user.username)
            | (models.User.email == user.email)
        )
    )
    if existing:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "username or email already exists"
        )

    row = models.User(
        username=user.username,
        email=user.email,
        password_hash=hash_password(user.password),
    )
    db.add(row)
    db.commit()
    db.refresh(row)

    token = create_verification_token(row.id)
    row.verification_token = token
    db.commit()
    send_verification_email(row.email, token)

    return row

@router.delete("/users/me", status_code=status.HTTP_204_NO_CONTENT)
def delete_current_user(current_user: CurrentUser, db: DbSession):
    def delete_account():
        # Account deletion changes membership too: use the same family-first
        # locking and retry policy as join/leave/remove.
        family = lock_membership(db, current_user)
        if family is not None:
            if family.admin_user_id == current_user.id:
                db.execute(
                    update(models.User)
                    .where(models.User.family_id == family.id)
                    .values(family_id=None)
                )
                delete_family(db, family)
            else:
                revoke_invitations(db, family.id, current_user.email)
        # Reports and violations are still removed by the ORM cascades.
        db.delete(current_user)

    mutate_family(db, delete_account)
