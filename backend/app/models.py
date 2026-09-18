from datetime import datetime
from sqlalchemy import (
    Boolean,
    DateTime,
    ForeignKey,
    Integer,
    Numeric,
    String,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship
from .database import Base

class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    username: Mapped[str] = mapped_column(String(50), unique=True)
    email: Mapped[str] = mapped_column(String(255), unique=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime | None] = mapped_column(
        DateTime, server_default=func.now()
    )
    email_verified: Mapped[bool] = mapped_column(Boolean, default=False)
    verification_token: Mapped[str | None] = mapped_column(String(255), nullable=True)
    verification_token_expires_at: Mapped[datetime | None] = mapped_column(
        DateTime, nullable=True
    )

    # Forgot-password flow: a short-lived 6-digit code, hashed like a password
    # so a DB leak never exposes a usable code
    reset_code_hash: Mapped[str | None] = mapped_column(String(255), nullable=True)
    reset_code_expires_at: Mapped[datetime | None] = mapped_column(
        DateTime, nullable=True
    )
    reset_code_attempts: Mapped[int] = mapped_column(Integer, default=0)

    # No passive_deletes. Letting SQLAlchemy delete the rows
    # itself makes DELETE /users/me clean up correctly either way
    driving_reports: Mapped[list["DrivingReport"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )
    violations: Mapped[list["Violation"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )

class DrivingReport(Base):
    """One saved driving report according to the driving_reports table.

    This is the finished report the driver saw at the end of a trip, stored so it
    can be looked at again later and compared against newer ones. The raw GPS
    samples behind it are only needed to produce these numbers in the first
    place, which happens on the device, so they aren't kept.

    Grades are the client-computed values shown live on the dashboard, stored
    verbatim so a saved report can never disagree with what the driver watched.
    """

    __tablename__ = "driving_reports"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)

    overall_grade: Mapped[float] = mapped_column(Numeric(5, 2, asdecimal=False))
    # The only dimension the app grades today, from SpeedGradingService
    speed_grade: Mapped[float] = mapped_column(Numeric(5, 2, asdecimal=False))
    # Not yet implemented in the app. The columns are NOT NULL, so the API fills
    # them with a placeholder - see UNGRADED_DIMENSION in schemas.py
    braking_grade: Mapped[float] = mapped_column(Numeric(5, 2, asdecimal=False))
    acceleration_grade: Mapped[float] = mapped_column(Numeric(5, 2, asdecimal=False))
    turning_grade: Mapped[float] = mapped_column(Numeric(5, 2, asdecimal=False))
    focus_grade: Mapped[float] = mapped_column(Numeric(5, 2, asdecimal=False))

    # Set to when the trip ended, not when the row was written, so a report that
    # uploads late (or is retried after a failure) still dates to the drive
    report_date: Mapped[datetime | None] = mapped_column(
        DateTime, server_default=func.now()
    )
    trip_duration_minutes: Mapped[float] = mapped_column(Numeric(5, 2, asdecimal=False))
    trip_distance_miles: Mapped[float] = mapped_column(Numeric(6, 2, asdecimal=False))

    user: Mapped["User"] = relationship(back_populates="driving_reports")
    violations: Mapped[list["Violation"]] = relationship(
        back_populates="driving_report",
        cascade="all, delete-orphan",
        # Chronological within a trip, so a read never returns them in whatever
        # order the rows happen to come back in
        order_by="Violation.start_time",
    )


class Violation(Base):
    """One violation inside a driving report, per the violations table.

    A report's grade says how the trip went overall; these rows say where and
    when it went wrong, so the driver can be shown the specific moments behind
    the grade rather than just a number.
    """

    __tablename__ = "violations"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    # Denormalized from the parent report so "every violation this user has ever
    # had" is one indexed lookup instead of a join
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    driving_report_id: Mapped[int] = mapped_column(
        ForeignKey("driving_reports.id"), index=True
    )

    # The column is a MySQL ENUM of the five graded dimensions, spelled exactly
    # as the app labels them - see VIOLATION_TYPES in schemas.py
    violation_type: Mapped[str] = mapped_column(String(32), index=True)

    # Nullable: road names come from the speed-limit lookup, which returns null
    # off-road or outside the OSM extract's coverage
    road_name: Mapped[str | None] = mapped_column(String(255), nullable=True)

    start_time: Mapped[datetime] = mapped_column(DateTime)
    end_time: Mapped[datetime] = mapped_column(DateTime)

    user: Mapped["User"] = relationship(back_populates="violations")
    driving_report: Mapped["DrivingReport"] = relationship(
        back_populates="violations"
    )
