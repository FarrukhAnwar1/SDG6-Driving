from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select
from .. import models, schemas
from ..dependencies import DbSession
from ..security import hash_password

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
    return row
