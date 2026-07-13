from datetime import datetime, timedelta

import jwt
from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select
from .. import models, schemas
from ..config import settings
from ..dependencies import CurrentUser, DbSession
from ..security import (
    create_verification_token,
    decode_verification_token,
    create_access_token,
    verify_password,
    hash_password,
    generate_reset_code,
    hash_reset_code,
    verify_reset_code,
)
from ..email import send_verification_email, send_password_reset_email

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

    # Prevent unverified users from logging in
    if not user.email_verified:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            "Please verify your email before logging in.",
        )

    token = create_access_token(subject=str(user.id))
    return schemas.Token(access_token=token)

# Lets a client verify its token and fetch the current user. Included so the JWT
# flow is testable end-to-end, the API attaches CurrentUser to the actual
# protected feature routes
@router.get("/me", response_model=schemas.UserOut)
def read_me(current_user: CurrentUser):
    return current_user

# Step 1 of the forgot-password flow: email a 6-digit code (rather than a link),
# which the client collects alongside a new password in POST /reset-password.
# A code entered in-app is the standard mobile pattern since it avoids relying
# on email-to-app deep linking.
@router.post("/forgot-password")
def forgot_password(payload: schemas.EmailRequest, db: DbSession):
    user = db.scalar(select(models.User).where(models.User.email == payload.email))

    # Same message whether or not the account exists, so callers can't use this
    # endpoint to discover which emails are registered
    generic_message = {
        "message": "If the email is registered, a password reset code has been sent."
    }

    if user is None:
        return generic_message

    code = generate_reset_code()
    user.reset_code_hash = hash_reset_code(code)
    user.reset_code_expires_at = datetime.utcnow() + timedelta(
        minutes=settings.password_reset_code_expire_minutes
    )
    user.reset_code_attempts = 0
    db.commit()
    send_password_reset_email(user.email, code)

    return generic_message

# Step 2: verify the code emailed above and set the new password in one call
@router.post("/reset-password")
def reset_password(payload: schemas.ResetPasswordRequest, db: DbSession):
    user = db.scalar(select(models.User).where(models.User.email == payload.email))

    invalid_code_exception = HTTPException(
        status.HTTP_400_BAD_REQUEST, "Invalid or expired reset code."
    )

    if user is None or user.reset_code_hash is None:
        raise invalid_code_exception

    if (
        user.reset_code_expires_at is None
        or datetime.utcnow() > user.reset_code_expires_at
    ):
        raise invalid_code_exception

    # Once too many wrong codes have been tried, force the user to request a fresh one
    if user.reset_code_attempts >= settings.password_reset_max_attempts:
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            "Too many attempts. Please request a new code.",
        )

    if not verify_reset_code(payload.code, user.reset_code_hash):
        user.reset_code_attempts += 1
        db.commit()
        raise invalid_code_exception

    user.password_hash = hash_password(payload.new_password)
    user.reset_code_hash = None
    user.reset_code_expires_at = None
    user.reset_code_attempts = 0
    db.commit()

    return {"message": "Password reset successfully."}