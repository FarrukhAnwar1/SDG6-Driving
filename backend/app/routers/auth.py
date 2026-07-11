import jwt
from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select
from .. import models, schemas
from ..dependencies import CurrentUser, DbSession
from ..security import create_verification_token, decode_verification_token, create_access_token, verify_password
from ..email import send_verification_email

router = APIRouter(tags=["auth"])

@router.get("/verify-email")
def verify_email(token: str, db: DbSession):
    try:
        user_id = decode_verification_token(token)
    except jwt.ExpiredSignatureError:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Verification token has expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Invalid verification token")
    
    user = db.get(models.User, user_id)
    if user is None: 
        raise HTTPException(status.HTTP_404_NOT_FOUND, "User not found")

    if user.email_verified:
        return {"message": "Email already verified"}
    
    # old link won't work if a new one is requested
    if user.verification_token != token:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "This link is no longer valid.")
    
    user.email_verified = True
    user.verification_token = None
    db.commit()
    return {"message": "Email verified successfully"}

@router.post("/resend-verification")
def resend_verification(payload: schemas.EmailRequest, db: DbSession):
    user = db.scalar(select(models.User).where(models.User.email == payload.email))

    if user is None or user.email_verified:
        return {"message": "If the email is registered and not verified, a new verification email will be sent."}
    
    token = create_verification_token(user.id)
    user.verification_token = token
    db.commit()
    send_verification_email(user.email, token)
    
    return {"message": "If the email is registered and not verified, a new verification email will be sent."}

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
