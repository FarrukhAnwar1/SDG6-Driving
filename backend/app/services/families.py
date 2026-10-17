from sqlalchemy import func, select
from sqlalchemy.orm import Session, aliased
from .. import models, schemas

GRADE_COLUMNS = (
    "overall_grade", "speed_grade", "braking_grade",
    "acceleration_grade", "turning_grade", "focus_grade",
)


def _num(value) -> float | None:
    # AVG/SUM come back as Decimal from MySQL
    return None if value is None else round(float(value), 2)


def read_family(db: Session, family: models.DrivingFamily) -> schemas.FamilyOut:
    """The family with each member's averages, latest drive and totals."""
    R = models.DrivingReport
    members = sorted(
        family.members, key=lambda u: (u.id != family.admin_user_id, u.id)
    )
    member_ids = [m.id for m in members]

    # One row per member who has reports: count, AVG of each grade, SUM of totals
    totals = {
        row.user_id: row
        for row in db.execute(
            select(
                R.user_id,
                func.count(R.id).label("drive_count"),
                *[func.avg(getattr(R, c)).label(c) for c in GRADE_COLUMNS],
                func.sum(R.trip_duration_minutes).label("minutes"),
                func.sum(R.trip_distance_miles).label("miles"),
            )
            .where(R.user_id.in_(member_ids))
            .group_by(R.user_id)
        )
    }

    # Each member's newest report. Reports with a NULL report_date sort last in
    # MySQL on DESC, so they only win if the member has nothing newer
    ranked = (
        select(
            R,
            func.row_number()
            .over(
                partition_by=R.user_id,
                order_by=(R.report_date.desc(), R.id.desc()),
            )
            .label("rn"),
        )
        .where(R.user_id.in_(member_ids))
        .subquery()
    )
    latest_report = aliased(R, ranked)
    latest = {
        r.user_id: r
        for r in db.scalars(select(latest_report).where(ranked.c.rn == 1))
    }

    out = []
    for m in members:
        t = totals.get(m.id)
        if t is None:
            out.append(
                schemas.FamilyMemberOut(
                    user_id=m.id,
                    username=m.username,
                    drive_count=0,
                    average_grades=None,
                    latest_drive=None,
                    total_driving_minutes=0,
                    total_distance_miles=0,
                )
            )
            continue
        out.append(
            schemas.FamilyMemberOut(
                user_id=m.id,
                username=m.username,
                drive_count=t.drive_count,
                average_grades=schemas.FamilyGradesOut(
                    **{c: _num(getattr(t, c)) for c in GRADE_COLUMNS}
                ),
                latest_drive=schemas.FamilyLatestDriveOut.model_validate(latest[m.id]),
                total_driving_minutes=_num(t.minutes) or 0,
                total_distance_miles=_num(t.miles) or 0,
            )
        )

    return schemas.FamilyOut(
        id=family.id, admin_user_id=family.admin_user_id, members=out
    )