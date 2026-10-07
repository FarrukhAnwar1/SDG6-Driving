# Defines the Pydantic models (schemas) used for request validation and 
# response serialization in the FastAPI application.
from datetime import datetime, timezone
from typing import List, Literal, Optional, get_args
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
    email: str        # what POST /resend-verification and /forgot-password accept
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
   """What GET /speed-limit returns for one coordinate.

   speed_limit_mph is null when no driveable road was found within the search
   radius, or when the nearest one carries no limit worth assuming - see
   services/speed_limits.py. road_name and distance_meters are still filled in
   that second case, so the app can say where it thinks the driver is even when
   it has nothing to grade them against.
   """

   speed_limit_mph: Optional[float] = Field(serialization_alias="speedLimitMph")
   road_name: Optional[str] = Field(default=None, serialization_alias="roadName")
   distance_meters: Optional[float] = Field(default=None, serialization_alias="distanceMeters")

   # How the limit was arrived at, so the app never treats an assumption as a
   # posted sign: "posted" read off the road, "inferred" assumed from its class,
   # "unknown" no limit at all
   speed_limit_source: Literal["posted", "inferred", "unknown"] = Field(
       default="unknown", serialization_alias="speedLimitSource"
   )
   # How far over the limit counts as speeding on this road. Sent with the limit
   # because the slack an assumed limit deserves depends on how tightly that
   # road class's postings cluster, which is a property of the OSM extract
   speeding_threshold_mph: Optional[float] = Field(
       default=None, serialization_alias="speedingThresholdMph"
   )

# The trip schemas below speak camelCase on the wire (matching SpeedLimitOut and
# what the Flutter client expects) while staying snake_case in Python
_CAMEL_CONFIG = ConfigDict(alias_generator=to_camel, populate_by_name=True)

def _to_naive_utc(value: datetime) -> datetime:
    """Normalize a timestamp to a naive UTC datetime.

    The Flutter app sends UTC with a Z suffix, which gets converted here; a
    naive value is stored as is. Converting everything tz-aware keeps every
    stored timestamp the same kind. MySQL DATETIME carries no timezone, and
    mixing naive and aware values makes later date arithmetic raise TypeError.
    """
    if value.tzinfo is None:
        return value
    return value.astimezone(timezone.utc).replace(tzinfo=None)


# The app sends all five grades, but it once sent speed alone and the braking,
# acceleration, turning and focus columns are NOT NULL. A client that omits one
# still gets this full marks placeholder rather than a failed INSERT
UNGRADED_DIMENSION = 100.0

# driving_reports.trip_duration_minutes is DECIMAL(5,2) and trip_distance_miles
# is DECIMAL(6,2). Values past these bounds would overflow the column and fail
# at INSERT, so reject them up front as a 422 rather than a 500
MAX_TRIP_DURATION_MINUTES = 999.99
MAX_TRIP_DISTANCE_MILES = 9999.99

# The five graded dimensions, spelled exactly 
# as the violations.violation_type ENUM in MySQL spells them
ViolationType = Literal[
    "Proper Speed",
    "Smooth Braking",
    "Smooth Accelerating",
    "Smooth Turning",
    "Focused Driving",
]
VIOLATION_TYPES = get_args(ViolationType)

# How the trip was driven, spelled exactly as the driving_reports.driving_mode
# ENUM in MySQL spells it. "regular" grades every dimension; "navigation" grades
# every dimension except focus, since following directions means glancing at
# the phone, so focus_grade is NULL and focus violations aren't recorded
DrivingMode = Literal["regular", "navigation"]
DRIVING_MODES = get_args(DrivingMode)

# Max violation count in case of bugs to prevent violations from keep on going on
MAX_VIOLATIONS_PER_REPORT = 500

class ViolationCreate(BaseModel):
    """One violation inside an uploaded report, as the app recorded it.

    The app records where a violation began; the violations table stores a road
    name instead, so the coordinates are resolved against the OSM road data on
    the way in and then dropped - see services/road_names.py.

    The grading services attach more than this to each violation (the posted
    limit and peak speed of a speeding streak, peak g-force of a smoothness
    violation, the speed the car was doing when the driver left the app). None
    of it has a column, so it is ignored rather than rejected: the client may
    send its whole violation object without the upload failing.
    """

    model_config = _CAMEL_CONFIG

    violation_type: ViolationType
    start_time: datetime
    end_time: datetime

    # Where the violation began. Required because every grading service records
    # a position with the violation and drops the violation when it has none
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)

    _normalize_start_time = field_validator("start_time")(_to_naive_utc)
    _normalize_end_time = field_validator("end_time")(_to_naive_utc)

    @model_validator(mode="after")
    def end_must_not_precede_start(self):
        # violations carries CHECK (end_time >= start_time). Without this the
        # constraint rejects the INSERT and the whole upload surfaces as a 500
        if self.end_time < self.start_time:
            raise ValueError("endTime must not be earlier than startTime")
        return self


class DrivingReportCreate(BaseModel):
    """POST /driving-reports accepts a finished report, graded client-side.

    Mirrors the Flutter TripSummary model, with the differences forced by the
    driving_reports and violations tables: duration is derived from the
    timestamps into decimal minutes, every grade but overall and speed may be
    omitted, and TripSummary's five separate violation lists arrive as one list
    tagged with the ENUM label each maps to.

    driving_mode defaults to "regular" so clients that predate modes keep
    working unchanged. A "navigation" report must leave focus out entirely: no
    focusGrade and no Focused Driving violations.
    """

    model_config = _CAMEL_CONFIG

    started_at: datetime
    ended_at: datetime
    trip_distance_miles: float = Field(ge=0, le=MAX_TRIP_DISTANCE_MILES)
    driving_mode: DrivingMode = "regular"

    overall_grade: float = Field(ge=0, le=100)
    speed_grade: float = Field(ge=0, le=100)
    braking_grade: float = Field(default=UNGRADED_DIMENSION, ge=0, le=100)
    acceleration_grade: float = Field(default=UNGRADED_DIMENSION, ge=0, le=100)
    turning_grade: float = Field(default=UNGRADED_DIMENSION, ge=0, le=100)
    # None until validated: a regular report then falls back to
    # UNGRADED_DIMENSION, while a navigation report keeps it None
    focus_grade: Optional[float] = Field(default=None, ge=0, le=100)

    # Optional, so the clients that only send grades keep working unchanged.
    # A trip with nothing to report legitimately has none
    violations: List[ViolationCreate] = Field(
        default_factory=list, max_length=MAX_VIOLATIONS_PER_REPORT
    )

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

    @model_validator(mode="after")
    def focus_matches_driving_mode(self):
        # driving_reports carries a CHECK pairing focus_grade IS NULL with
        # navigation mode, so a mismatch is caught here as a 422 rather than
        # failing the INSERT as a 500
        if self.driving_mode == "navigation":
            if self.focus_grade is not None:
                raise ValueError("focusGrade must be omitted in navigation mode")
            if any(v.violation_type == "Focused Driving" for v in self.violations):
                raise ValueError(
                    "Focused Driving violations are not tracked in navigation mode"
                )
        elif self.focus_grade is None:
            self.focus_grade = UNGRADED_DIMENSION
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
    driving_mode: DrivingMode
    overall_grade: float
    speed_grade: float
    braking_grade: float
    acceleration_grade: float
    turning_grade: float
    # Null on navigation reports, which don't grade focus
    focus_grade: Optional[float] = None
    report_date: Optional[datetime] = None
    trip_duration_minutes: float
    trip_distance_miles: float



class ViolationOut(BaseModel):
    """One violation as stored, nested inside the report it belongs to.

    user_id and driving_report_id are left out: the report is already the
    caller's own and already identifies itself, so both would be noise.
    """

    model_config = ConfigDict(
        alias_generator=to_camel, populate_by_name=True, from_attributes=True
    )

    id: int
    violation_type: ViolationType
    # Null when the speed-limit lookup had no road name for the spot
    road_name: Optional[str] = None
    start_time: datetime
    end_time: datetime


class DrivingReportWithViolationsOut(DrivingReportOut):
    """A saved report plus the violations recorded during that trip."""

    violations: List[ViolationOut] = []


# GET /driving-reports returns the caller's most recent reports. The default
# keeps a first page cheap; the cap stops one request from pulling an entire
# history, and every violation under it, into memory
DEFAULT_REPORT_LIMIT = 10
MAX_REPORT_LIMIT = 100


class DrivingReportsOut(BaseModel):
    # what GET /driving-reports returns, newest trip first
    reports: List[DrivingReportWithViolationsOut]


class FeedbackMessage(BaseModel):
    """The only field generated by Gemini, validated before it reaches the UI."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    message: str = Field(min_length=1, max_length=1200)


class AdvancedSuggestionOut(FeedbackMessage):
    """One displayable message, with history metadata supplied by the backend."""

    model_config = ConfigDict(
        alias_generator=to_camel, populate_by_name=True,
        extra="forbid", str_strip_whitespace=True,
    )
    status: Literal["ready", "insufficient_history"]
    reports_analyzed: int = Field(ge=0)
    analysis_start_date: Optional[datetime] = None
    analysis_end_date: Optional[datetime] = None
