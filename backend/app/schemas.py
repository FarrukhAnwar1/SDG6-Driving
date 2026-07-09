from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel, ConfigDict

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