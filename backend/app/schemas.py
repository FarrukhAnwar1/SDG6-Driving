from datetime import datetime, timezone
from typing import List, Optional
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from pydantic.alias_generators import to_camel

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

# The trip schemas below speak camelCase on the wire (matching SpeedLimitOut and
# what the Flutter client expects) while staying snake_case in Python
_CAMEL_CONFIG = ConfigDict(alias_generator=to_camel, populate_by_name=True)

def _to_naive_utc(value: datetime) -> datetime:
    """Normalize a timestamp to a naive UTC datetime.

    The Flutter app sends local times with no UTC offset today, which arrive
    naive and are stored as is. Anything tz-aware gets converted so that every
    stored timestamp is the same kind. MySQL DATETIME carries no timezone, and
    mixing naive and aware values makes later date arithmetic raise TypeError.
    """
    if value.tzinfo is None:
        return value
    return value.astimezone(timezone.utc).replace(tzinfo=None)


# braking, acceleration, turning and focus aren't graded by the app yet, but
# their columns are NOT NULL. A full marks placeholder keeps them from dragging
# down overall_grade in any later averaging - see the README for why making
# these columns nullable would be the better long-term fix
UNGRADED_DIMENSION = 100.0

# driving_reports.trip_duration_minutes is DECIMAL(5,2) and trip_distance_miles
# is DECIMAL(6,2). Values past these bounds would overflow the column and fail
# at INSERT, so reject them up front as a 422 rather than a 500
MAX_TRIP_DURATION_MINUTES = 999.99
MAX_TRIP_DISTANCE_MILES = 9999.99

class DrivingReportCreate(BaseModel):
    """POST /driving-reports accepts a finished report, graded client-side.

    Mirrors the Flutter TripSummary model, with three differences forced by the
    driving_reports table: duration is derived from the timestamps into decimal
    minutes, the four ungraded dimensions may be omitted, and
    speedingOffenseCount / totalSpeedingDuration have no column to live in
    and are not accepted.
    """

    model_config = _CAMEL_CONFIG

    started_at: datetime
    ended_at: datetime
    trip_distance_miles: float = Field(ge=0, le=MAX_TRIP_DISTANCE_MILES)

    overall_grade: float = Field(ge=0, le=100)
    speed_grade: float = Field(ge=0, le=100)
    braking_grade: float = Field(default=UNGRADED_DIMENSION, ge=0, le=100)
    acceleration_grade: float = Field(default=UNGRADED_DIMENSION, ge=0, le=100)
    turning_grade: float = Field(default=UNGRADED_DIMENSION, ge=0, le=100)
    focus_grade: float = Field(default=UNGRADED_DIMENSION, ge=0, le=100)

    _normalize_started_at = field_validator("started_at")(_to_naive_utc)
    _normalize_ended_at = field_validator("ended_at")(_to_naive_utc)

    @model_validator(mode="after")
    def end_must_not_precede_start(self):
        if self.ended_at < self.started_at:
            raise ValueError("endedAt must not be earlier than startedAt")
        if self.trip_duration_minutes > MAX_TRIP_DURATION_MINUTES:
            raise ValueError(
                f"trip must be shorter than {MAX_TRIP_DURATION_MINUTES} minutes"
            )
        return self

    @property
    def trip_duration_minutes(self) -> float:
        # Derived rather than sent, so it can never disagree with the timestamps
        return round((self.ended_at - self.started_at).total_seconds() / 60, 2)


class DrivingReportOut(BaseModel):
    # what POST /driving-reports returns, the saved report as stored
    model_config = ConfigDict(
        alias_generator=to_camel, populate_by_name=True, from_attributes=True
    )

    id: int
    overall_grade: float
    speed_grade: float
    braking_grade: float
    acceleration_grade: float
    turning_grade: float
    focus_grade: float
    report_date: Optional[datetime] = None
    trip_duration_minutes: float
    trip_distance_miles: float