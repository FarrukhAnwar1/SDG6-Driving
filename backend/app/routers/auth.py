from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select

from .. import models, schemas
from ..dependencies import CurrentUser, DbSession
from ..security import create_access_token, verify_password

router = APIRouter(tags=["auth"])

@router.post("/login", response_model=schemas.Token)
def login(credentials: schemas.LoginRequest, db: DbSession):
    user = db.scalar(
        select(models.User).where(models.User.email == credentials.email)
    )
    # One generic error for no such user and wrong password
    if user is None or not verify_password(credentials.password, user.password_hash):
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED, "Incorrect email or password"
        )
    token = create_access_token(subject=str(user.id))
    return schemas.Token(access_token=token)

# Lets a client verify its token and fetch the current user. Included so the JWT
# flow is testable end-to-end, the API attaches CurrentUser to the actual
# protected feature routes
@router.get("/me", response_model=schemas.UserOut)
def read_me(current_user: CurrentUser):
    return current_user
