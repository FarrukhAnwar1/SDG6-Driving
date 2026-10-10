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

    # NULL means no family, which is the default on signup. An admin's own row
    # points at the family they administer, so they are listed among its members.
    # use_alter breaks the users <-> driving_families FK cycle for create_all
    family_id: Mapped[int | None] = mapped_column(
        ForeignKey("driving_families.id", ondelete="SET NULL", use_alter=True),
        nullable=True,
        default=None,
    )
    family: Mapped["DrivingFamily | None"] = relationship(
        foreign_keys=[family_id],
        back_populates="members",
        post_update=True,
    )
    administered_family: Mapped["DrivingFamily | None"] = relationship(
        foreign_keys="DrivingFamily.admin_user_id",
        back_populates="admin",
        cascade="all, delete-orphan",
    )
    sent_invitations: Mapped[list["FamilyInvitation"]] = relationship(
        back_populates="invited_by",
        cascade="all, delete-orphan",
    )

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


class DrivingFamily(Base):
    """One Driving Family, per the driving_families table.

    A family is a group of drivers who can see each other's report summaries.
    It has no name, and membership lives on users.family_id rather than in a
    join table, so a user belongs to at most one family. The admin is the user
    who created it and is the only one who can invite or remove members.
    """

    __tablename__ = "driving_families"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    # Unique so the same user can't create more than one family
    admin_user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), unique=True
    )
    created_at: Mapped[datetime | None] = mapped_column(
        DateTime, server_default=func.now()
    )

    admin: Mapped["User"] = relationship(
        foreign_keys=[admin_user_id], back_populates="administered_family"
    )
    # No delete cascade: deleting a family drops its members back to no family
    # rather than deleting their accounts. post_update clears their family_id in
    # a separate UPDATE, since the admin's row and this one point at each other
    members: Mapped[list["User"]] = relationship(
        foreign_keys="User.family_id",
        back_populates="family",
        post_update=True,
    )
    invitations: Mapped[list["FamilyInvitation"]] = relationship(
        back_populates="family",
        cascade="all, delete-orphan",
    )


class FamilyInvitation(Base):
    """One outstanding invitation to join a family, per family_invitations.

    A row lives only until it is redeemed: joining deletes it in the same
    transaction that sets the user's family_id, which is what makes each code
    single use. Only the code's hash is stored. It is a SHA-256 digest rather
    than bcrypt so the join endpoint can find the row from the code alone.
    """

    __tablename__ = "family_invitations"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    family_id: Mapped[int] = mapped_column(
        ForeignKey("driving_families.id", ondelete="CASCADE")
    )
    # Stored normalized (trimmed, lowercased) - see normalize_email in schemas.py
    email: Mapped[str] = mapped_column(String(255), index=True)
    invited_by_user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE")
    )
    # Hex SHA-256 of the emailed join code
    code_hash: Mapped[str] = mapped_column(String(64), unique=True)
    created_at: Mapped[datetime | None] = mapped_column(
        DateTime, server_default=func.now()
    )

    family: Mapped["DrivingFamily"] = relationship(back_populates="invitations")
    invited_by: Mapped["User"] = relationship(back_populates="sent_invitations")
