from fastapi import APIRouter, Query, status
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from .. import models, schemas
from ..dependencies import CurrentUser, DbSession

router = APIRouter(tags=["driving-reports"])

@router.post(
    "/driving-reports",
    response_model=schemas.DrivingReportOut,
    status_code=status.HTTP_201_CREATED,
)
def create_driving_report(
    payload: schemas.DrivingReportCreate,
    current_user: CurrentUser,
    db: DbSession,
):
    """Save a finished driving report for the authenticated user.

    The report is always attributed to the caller's token, never to a user id in
    the body, so one account can't file reports against another.

    Grades are stored exactly as the client computed them"""
    report = models.DrivingReport(
        user_id=current_user.id,
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

    db.add(report)
    db.commit()
    db.refresh(report)

    return report


@router.get("/driving-reports", response_model=schemas.DrivingReportsOut)
def list_driving_reports(
    current_user: CurrentUser,
    db: DbSession,
    limit: int = Query(
        default=schemas.DEFAULT_REPORT_LIMIT,
        ge=1,
        le=schemas.MAX_REPORT_LIMIT,
        description="How many of the most recent reports to return",
    ),
):
    """Return the authenticated user's last `limit` reports, newest trip first.

    Each report carries the violations recorded during that trip, so the report
    history screen can show what went wrong without a second round trip.

    The query is scoped to the caller's token, so one account can never read
    another's history.
    """
    reports = db.scalars(
        select(models.DrivingReport)
        .where(models.DrivingReport.user_id == current_user.id)
        # One extra query for all the violations at once, rather than one per
        # report as the response model walks the rows
        .options(selectinload(models.DrivingReport.violations))
        # report_date is the trip's end time, so this orders by when people drove
        # rather than when the uploads landed. id breaks ties, since MySQL
        # DATETIME has no sub-second precision here
        .order_by(
            models.DrivingReport.report_date.desc(),
            models.DrivingReport.id.desc(),
        )
        .limit(limit)
    ).all()

    return schemas.DrivingReportsOut(reports=reports)
