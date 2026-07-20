from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel, ConfigDict, Field, field_validator

class UserCreate(BaseModel):
    # what POST /users accepts, password is hashed server-side before storing
    username: str
    email: str
    password: str

class UserOut(BaseModel):
    # what the API returns, password_hash and verification tokens are omitted
    model_config = ConfigDict(from_attributes=True)
    id: int
    username: str
    email: str
    created_at: Optional[datetime] = None
    email_verified: bool

class Users(BaseModel):
    users: List[UserOut]

class EmailRequest(BaseModel):
    email: str        # what POST /auth/request-verification accepts
class LoginRequest(BaseModel):
    # what POST /login accepts
    email: str
    password: str

class Token(BaseModel):
    # what POST /login returns on success
    access_token: str
    token_type: str = "bearer"

class ResetPasswordRequest(BaseModel):
    # what POST /reset-password accepts, code is the 6-digit code emailed by /forgot-password
    email: str
    code: str
    new_password: str = Field(min_length=8)

class ChangePasswordRequest(BaseModel):
    # what POST /change-password accepts, current_password is the user's current password, 
    # new_password is the desired new password (>8 characters, different from current password)
    current_password: str
    new_password: str = Field(..., min_length=8, max_length=72)

    @field_validator("new_password")
    @classmethod
    def new_password_must_differ(cls, new_password, info):
        current_password = info.data.get("current_password")
        if current_password is not None and new_password == current_password:
            raise ValueError("New password must be different from the current password.")
        return new_password

class SpeedLimitOut(BaseModel):
   # what GET / speed-limit returns, speed_limit_mph is null when no tagged road is found within search radius
   speed_limit_mph: Optional[float] = Field(serialization_alias="speedLimitMph")
   road_name: Optional[str] = Field(default=None, serialization_alias="roadName")
   distance_meters: Optional[float] = Field(default=None, serialization_alias="distanceMeters")