from fastapi import APIRouter, status

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
