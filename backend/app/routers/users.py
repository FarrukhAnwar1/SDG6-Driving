from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select
from .. import models, schemas
from ..dependencies import CurrentUser, DbSession
from ..security import hash_password, create_verification_token
from ..email import send_verification_email

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
    # Deletes the authenticated user's own account
    db.delete(current_user)
    db.commit()
