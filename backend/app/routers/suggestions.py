# This file contains the endpoint for generating advanced suggestions based on a user's driving history. 
# It uses services from driving_reports and suggestions to fetch data and analyze it, 
# returning feedback to the user.
from fastapi import APIRouter, HTTPException, Response
from .. import schemas
from ..dependencies import CurrentUser, DbSession
from ..services.driving_reports import read_driving_reports
from ..services.suggestions import analyze_history, generate_feedback, SuggestionError

router = APIRouter(tags=["suggestions"])


@router.get(
    "/advanced-suggestion",
    response_model=schemas.AdvancedSuggestionOut,
    responses={
        401: {"description": "Invalid or expired access token"},
        429: {"description": "Gemini quota exhausted"},
        502: {"description": "Invalid or unusable Gemini response"},
        503: {"description": "Gemini is unconfigured or unavailable"},
        504: {"description": "Gemini request timed out"},
    },
)
def advanced_suggestion(current_user: CurrentUser, db: DbSession, response: Response):
    """Blend motivation and actionable advice from the caller's latest 100 trips."""
    response.headers["Cache-Control"] = "no-store"
    rows = read_driving_reports(db, current_user.id, schemas.MAX_REPORT_LIMIT)
    reports = [schemas.DrivingReportWithViolationsOut.model_validate(row) for row in rows]
    history = analyze_history(reports)
    metadata = {
        "reportsAnalyzed": history["reportsAnalyzed"],
        "analysisStartDate": history["analysisStartDate"],
        "analysisEndDate": history["analysisEndDate"],
    }

    if not history["hasSufficientHistory"]:
        return schemas.AdvancedSuggestionOut(
            status="insufficient_history",
            message=(
                "Start building your driving history by saving your trips. "
                "Once you have at least 6 dated trips spanning 28 days, "
                "you'll receive feedback on your progress and what to work on."
                if not reports else
                "Keep recording your trips to build a clearer picture of your driving. "
                "Long-term feedback needs at least 6 dated trips spanning 28 days."
            ),
            **metadata,
        )

    try:
        message = generate_feedback(history)
    except SuggestionError as exc:
        raise HTTPException(
            status_code=exc.status_code, detail=exc.detail,
            headers={"Cache-Control": "no-store"},
        ) from exc
    return schemas.AdvancedSuggestionOut(status="ready", message=message, **metadata)
