import jwt
from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select
from .. import models, schemas
from ..dependencies import DbSession
from ..security import create_verification_token, decode_verification_token
from ..email import send_verification_email

router = APIRouter(prefix="/auth", tags=["auth"])

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