# Contains the endpoints for creating and reading driving reports.
# The actual database queries are in services/driving_reports.py, 
# which is imported here to keep the router file clean and focused 
# on request/response handling.
from fastapi import APIRouter, Query, status
from .. import schemas
from ..dependencies import CurrentUser, DbSession, PgSession
from ..services.driving_reports import read_driving_reports, write_driving_report
from ..services.road_names import resolve_road_names

router = APIRouter(tags=["driving-reports"])

@router.post(
    "/driving-reports",
    response_model=schemas.DrivingReportWithViolationsOut,
    status_code=status.HTTP_201_CREATED,
)
def create_driving_report(
    payload: schemas.DrivingReportCreate,
    current_user: CurrentUser,
    db: DbSession,
    pg_db: PgSession,
):
    """Save a finished driving report, and the violations behind it, for the
    authenticated user.

    Grades are stored exactly as the client computed them. Each violation
    arrives with the coordinates where it began, which the violations table has
    nowhere to put: they are resolved to a road name here and dropped. The
    saved violations come back in the response, so the client sees the names the
    server settled on without re-reading its own upload.

    pg_db opens no connection when the report carries no violations
    """
    road_names = resolve_road_names(
        pg_db,
        [(violation.latitude, violation.longitude) for violation in payload.violations],
    )

    return write_driving_report(db, current_user.id, payload, road_names)


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
    reports = read_driving_reports(db, current_user.id, limit)

    return schemas.DrivingReportsOut(reports=reports)
