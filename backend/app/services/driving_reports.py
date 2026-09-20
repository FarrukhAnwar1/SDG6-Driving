# Provides a single query to load a user's latest trips and their violations for both read endpoints
# (GET /driving-reports and GET /advanced-suggestion).
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload
from .. import models


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
