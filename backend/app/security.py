import bcrypt
import jwt
from datetime import datetime, timedelta, timezone
from .config import settings

# Hashes a plaintext password with bcrypt
def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")

# Verifies a plaintext password against a hashed password
def create_verification_token(user_id: int) -> str:
    payload = {
        "sub": str(user_id),
        "purpose": "email_verification",
        "exp": datetime.now(timezone.utc) + timedelta(hours=settings.verification_token_expire_hours)
    }
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)

# Decodes a verification token and returns the user ID if valid
def decode_verification_token(token: str) -> int:
    payload = jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
    if payload.get("purpose") != "email_verification":
        raise jwt.InvalidTokenError("Invalid token purpose")
    return int(payload["sub"])