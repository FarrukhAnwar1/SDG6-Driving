# Provides a single query to load a user's latest trips and their violations for both read endpoints
# (GET /driving-reports and GET /advanced-suggestion).
import hashlib
import json
from typing import Sequence
from uuid import NAMESPACE_URL, uuid5

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload
from .. import models, schemas


def _upload_identity(user_id: int, payload: schemas.DrivingReportCreate) -> tuple[str, str]:
    normalized = payload.model_dump(mode="json", exclude={"client_trip_id"})
    digest = hashlib.sha256(json.dumps(
        normalized, sort_keys=True, separators=(",", ":"), allow_nan=False,
    ).encode("utf-8")).hexdigest()
    trip_id = str(payload.client_trip_id or uuid5(NAMESPACE_URL, f"drive:{user_id}:{digest}"))
    return trip_id, digest


def find_existing_report(
    db: Session, user_id: int, payload: schemas.DrivingReportCreate,
) -> models.DrivingReport | None:
    trip_id, digest = _upload_identity(user_id, payload)
    existing = db.scalar(select(models.DrivingReport).where(
        models.DrivingReport.user_id == user_id,
        models.DrivingReport.client_trip_id == trip_id,
    ))
    if existing is not None and existing.upload_payload_hash != digest:
        raise HTTPException(409, "This trip ID has already been used for a different report.")
    return existing


def read_driving_reports(
    db: Session, user_id: int, limit: int
) -> list[models.DrivingReport]:
    """Load a user's latest trips and their violations for both read endpoints."""
    return list(db.scalars(
        select(models.DrivingReport)
        .where(models.DrivingReport.user_id == user_id)
        # Load all violations in one extra query, also checking their owner
        .options(selectinload(models.DrivingReport.violations.and_(
            models.Violation.user_id == user_id
        )))
        # Late uploads keep their trip date while id breaks same-second ties
        .order_by(
            models.DrivingReport.report_date.desc(),
            models.DrivingReport.id.desc(),
        )
        .limit(limit)
    ).all())


def write_driving_report(
    db: Session,
    user_id: int,
    payload: schemas.DrivingReportCreate,
    road_names: Sequence[str | None],
) -> models.DrivingReport:
    """Insert one finished report and its violations as a single transaction.

    The violations are attached through the relationship rather than inserted
    separately, so SQLAlchemy writes the report first and fills each row's
    driving_report_id from the id it gets back. Either the whole trip lands or
    none of it does - a report whose violations failed halfway would read as a
    cleaner drive than it was.

    `road_names` lines up with payload.violations positionally, as returned by
    services/road_names.resolve_road_names.
    """
    existing = find_existing_report(db, user_id, payload)
    if existing is not None:
        return existing
    trip_id, digest = _upload_identity(user_id, payload)
    report = models.DrivingReport(
        user_id=user_id,
        client_trip_id=trip_id,
        upload_payload_hash=digest,
        driving_mode=payload.driving_mode,
        overall_grade=payload.overall_grade,
        speed_grade=payload.speed_grade,
        braking_grade=payload.braking_grade,
        acceleration_grade=payload.acceleration_grade,
        turning_grade=payload.turning_grade,
        focus_grade=payload.focus_grade,
        # When the trip ended, rather than the column's CURRENT_TIMESTAMP default,
        # so a report that uploads late still dates to the drive itself
        report_date=payload.ended_at,
        trip_duration_minutes=payload.trip_duration_minutes,
        trip_distance_miles=payload.trip_distance_miles,
    )

    for violation, road_name in zip(payload.violations, road_names, strict=True):
        report.violations.append(
            models.Violation(
                # Denormalized onto the row, matching the column, so a user's
                # whole violation history is one indexed lookup
                user_id=user_id,
                violation_type=violation.violation_type,
                road_name=road_name,
                start_time=violation.start_time,
                end_time=violation.end_time,
            )
        )

    db.add(report)
    try:
        db.commit()
    except IntegrityError:
        # A simultaneous retry may have passed the initial read. The unique
        # constraint chooses one winner; rollback also ends a MySQL RR snapshot.
        db.rollback()
        existing = find_existing_report(db, user_id, payload)
        if existing is None:
            raise
        return existing
    db.refresh(report)
    return report
