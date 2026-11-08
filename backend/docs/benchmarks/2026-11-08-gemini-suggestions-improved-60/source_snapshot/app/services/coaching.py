"""Build evidence-backed coaching choices and render their exact display text.

Gemini chooses a focus from this request-specific catalog. Numbers, factual
claims, and actionable instructions are rendered here rather than invented by
the model. Full driving history remains available to the selector.
"""

from dataclasses import dataclass
from datetime import datetime, timezone
from statistics import fmean

from ..schemas import FeedbackMessage, FeedbackSelection


# One independently executable behavior per action, with no invented speed
# limit, cause, road condition, or promised score/safety improvement.
CATEGORIES = {
    "speed": ("speedGrade", "speed", "Proper Speed", "monitor_speed",
              "On your next drives, check your speed against posted limits."),
    "braking": ("brakingGrade", "braking", "Smooth Braking", "brake_early",
                "When approaching a stop, begin slowing early enough to brake gradually."),
    "acceleration": ("accelerationGrade", "acceleration", "Smooth Accelerating", "accelerate_gradually",
                     "When pulling away, press the accelerator progressively."),
    "turning": ("turningGrade", "turning", "Smooth Turning", "steer_gradually",
                "Use gradual steering inputs through turns."),
    "focus": ("focusGrade", "focus", "Focused Driving", "reduce_notifications",
              "Before your next drive, enable Do Not Disturb to reduce notifications."),
    "following_distance": ("followingDistanceGrade", "following-distance", "Adequate Following Distance", "leave_space",
                           "As traffic moves, leave a larger gap behind the vehicle ahead."),
}


def _date(value):
    if value is None:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.astimezone(timezone.utc).replace(tzinfo=None) if parsed.tzinfo else parsed


def _number(value):
    return f"{value:.2f}".rstrip("0").rstrip(".")


def _measured(row, category, field):
    mode = row["drivingMode"]
    if category == "focus" and mode != "regular":
        return False
    if category == "following_distance" and mode == "pocket":
        return False
    return row["tripDurationMinutes"] > 0 and row.get(field) is not None


@dataclass(frozen=True)
class CoachingOption:
    id: str
    category: str
    text: str
    evidence: dict

    def prompt_data(self):
        return {"id": self.id, "category": self.category, "text": self.text, "evidence": self.evidence}


@dataclass(frozen=True)
class CoachingChoices:
    observations: dict[str, CoachingOption]
    actions: dict[str, CoachingOption]
    constraints: dict

    def prompt_data(self):
        return {
            "motivational_observations": [option.prompt_data() for option in self.observations.values()],
            "actionable_suggestions": [option.prompt_data() for option in self.actions.values()],
            "constraints": self.constraints,
        }

    def response_schema(self):
        schema = FeedbackSelection.model_json_schema()
        schema["properties"]["motivational_observation"]["enum"] = list(self.observations)
        schema["properties"]["actionable_suggestion"]["enum"] = list(self.actions)
        return schema

    def render(self, selection: FeedbackSelection) -> str:
        observation = self.observations.get(selection.motivational_observation)
        action = self.actions.get(selection.actionable_suggestion)
        if observation is None or action is None:
            raise ValueError("Selection is not one of this history's approved choices")
        return FeedbackMessage(message=f"{observation.text} {action.text}").message


def build_coaching_choices(history: dict) -> CoachingChoices:
    reports = history["reports"]
    positive = [row for row in reports if row["tripDurationMinutes"] > 0]
    split = _date(history["comparison"]["splitDate"]) if history.get("comparison") else None
    improvements = {}
    strengths = {}
    actions = {}
    weaknesses = {}
    declining = set()
    unmeasured = []

    for category, (field, label, kind, action_id, action_text) in CATEGORIES.items():
        measured = [row for row in positive if _measured(row, category, field)]
        if not measured:
            unmeasured.append(category)
            continue
        # A single measured trip cannot establish a pattern across trips.
        if len(measured) < 2:
            continue
        average = round(fmean(row[field] for row in measured), 2)
        event_count = sum(event["violationType"] == kind for row in measured for event in row["violations"])
        evidence = {
            "category": category, "measuredReportIds": [row["id"] for row in measured],
            "measuredReportCount": len(measured), "averageGrade": average,
            "recordedViolationCount": event_count,
            "drivingMinutes": round(sum(row["tripDurationMinutes"] for row in measured), 2),
        }
        action = CoachingOption(action_id, category, action_text, evidence)
        actions[action_id] = action
        if average < 85 or event_count:
            weaknesses[action_id] = action
        if average >= 85:
            option_id = f"strength_{category}"
            strengths[option_id] = CoachingOption(
                option_id, category,
                f"Your recorded {label} grade averaged {_number(average)} out of 100 across "
                f"{len(measured)} trips with driving time, giving you a strength to build on.", evidence,
            )

        if split is None:
            continue
        # Compare within a mode and within the same calendar halves. In
        # particular, dropping focus/following by changing mode is not progress.
        for mode in sorted({row["drivingMode"] for row in measured}):
            dated = [(row, _date(row["reportDate"])) for row in measured
                     if row["drivingMode"] == mode and row["reportDate"] is not None]
            earlier = [row for row, day in dated if day <= split]
            recent = [row for row, day in dated if day > split]
            if len(earlier) < 2 or len(recent) < 2:
                continue
            before = round(fmean(row[field] for row in earlier), 2)
            after = round(fmean(row[field] for row in recent), 2)
            if after < before:
                declining.add(category)
            if after - before < 1:
                continue
            option_id = f"improved_{category}_{mode}"
            improvements[option_id] = CoachingOption(
                option_id, category,
                f"Across your recorded trips in {mode} mode, your average {label} grade rose from "
                f"{_number(before)} to {_number(after)} out of 100 between the earlier and recent "
                "periods, showing progress in that category.",
                {"category": category, "drivingMode": mode, "earlierAverage": before,
                 "recentAverage": after, "earlierReportIds": [row["id"] for row in earlier],
                 "recentReportIds": [row["id"] for row in recent]},
            )

    tracking = CoachingOption(
        "tracking_history", "recording",
        f"Saving these {len(reports)} trip reports gives you a useful record to reflect on.",
        {"reportCount": len(reports)},
    )
    observations = improvements or strengths or {tracking.id: tracking}
    if not actions:
        action_id = "check_driving_duration" if not positive else "record_more_measured_trips"
        text = ("Check that your next saved trip report includes driving time." if not positive else
                "Save more trips with recorded driving time so feedback can reflect repeat patterns.")
        action = CoachingOption(action_id, "recording", text, {"reportsWithDrivingTime": len(positive)})
        actions = {action.id: action}
    else:
        actions = weaknesses or actions

    return CoachingChoices(observations, actions, {
        "hasVerifiedImprovement": bool(improvements),
        "decliningGradeCategories": sorted(declining),
        "unmeasuredCategories": unmeasured,
        "reportsWithDrivingTime": len(positive),
        "zeroDrivingExposure": not positive,
        "undatedReportCount": sum(row["reportDate"] is None for row in reports),
        "undatedReportsCannotEstablishChronology": True,
        "zeroViolationCountDoesNotImplyPerfectGrade": True,
        "missingWeeksAreUnobserved": True,
        "gradeComparisonsAreWithinTheSameMode": True,
    })
