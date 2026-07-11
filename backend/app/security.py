import bcrypt
import jwt
from datetime import datetime, timedelta, timezone
from .config import settings

# Hashes a plaintext password with bcrypt
def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")

# Creates a signed, time-limited JWT used to prove ownership of an email address
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

# Verifies a plaintext password against a stored bcrypt hash
def verify_password(password: str, password_hash: str) -> bool:
    return bcrypt.checkpw(password.encode("utf-8"), password_hash.encode("utf-8"))

# Creates a signed JWT access token, subject identifies the user (their id)
def create_access_token(subject: str) -> str:
    expire = datetime.now(timezone.utc) + timedelta(
        minutes=settings.access_token_expire_minutes
    )
    payload = {"sub": subject, "exp": expire}
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)

# Decodes and validates a JWT, raises jwt.PyJWTError if invalid or expired
def decode_access_token(token: str) -> dict:
    return jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
