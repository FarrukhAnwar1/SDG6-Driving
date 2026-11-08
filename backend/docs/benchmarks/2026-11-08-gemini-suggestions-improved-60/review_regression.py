"""Reproduce this run's direct Codex AI source review, without reading judge labels.

Reference arithmetic below reads the saved reports independently of production
statistics. Single-action meanings were reviewed by Codex (AI), not humans.
Run only after all 60 requested logical attempts have been saved.
"""

from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys

OUT = Path(__file__).resolve().parent
BACKEND = OUT.parents[2]
sys.path.insert(0, str(BACKEND))

from app.schemas import FeedbackSelection
from app.services.coaching import build_coaching_choices
from tools.benchmark_suggestions import Assessment, format_checks


# Independent wire-field/exposure policy, rather than the producer's field map.
FIELDS = {
    "speed": ("speedGrade", "speed", "Proper Speed", {"regular", "navigation", "pocket"}),
    "braking": ("brakingGrade", "braking", "Smooth Braking", {"regular", "navigation", "pocket"}),
    "acceleration": ("accelerationGrade", "acceleration", "Smooth Accelerating", {"regular", "navigation", "pocket"}),
    "turning": ("turningGrade", "turning", "Smooth Turning", {"regular", "navigation", "pocket"}),
    "focus": ("focusGrade", "focus", "Focused Driving", {"regular"}),
    "following_distance": ("followingDistanceGrade", "following-distance", "Adequate Following Distance", {"regular", "navigation"}),
}
ACTIONS = {
    "monitor_speed": ("speed", "On your next drives, check your speed against posted limits.",
                      "One concrete speed-monitoring behavior; no speed-limit value or past cause is asserted."),
    "brake_early": ("braking", "When approaching a stop, begin slowing early enough to brake gradually.",
                    "One coordinated braking maneuver; timing and gradualness describe that maneuver, not independent recommendations."),
    "accelerate_gradually": ("acceleration", "When pulling away, press the accelerator progressively.",
                             "One concrete accelerator-input behavior."),
    "steer_gradually": ("turning", "Use gradual steering inputs through turns.",
                        "One concrete steering-input behavior."),
    "reduce_notifications": ("focus", "Before your next drive, enable Do Not Disturb to reduce notifications.",
                              "One prospective notification-setting action; it does not claim notifications caused past focus events."),
    "leave_space": ("following_distance", "As traffic moves, leave a larger gap behind the vehicle ahead.",
                    "One concrete vehicle-spacing behavior, without an invented distance or guaranteed result."),
    "check_driving_duration": ("recording", "Check that your next saved trip report includes driving time.",
                               "One concrete report-quality check when driving exposure is missing."),
    "record_more_measured_trips": ("recording", "Save more trips with recorded driving time so feedback can reflect repeat patterns.",
                                   "One concrete recording action to obtain repeated measurements."),
}


def day(value):
    if value is None:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.astimezone(timezone.utc).replace(tzinfo=None) if parsed.tzinfo else parsed


def measured(reports, category):
    field, _, _, modes = FIELDS[category]
    return [report for report in reports if report["drivingMode"] in modes
            and report["tripDurationMinutes"] > 0 and report.get(field) is not None]


def average(reports, category):
    field = FIELDS[category][0]
    return round(sum(report[field] for report in reports) / len(reports), 2)


manifest = json.loads((OUT / "manifest.json").read_text())
assert manifest["histories"] == 20 and manifest["repeats"] == 3
for name, expected in manifest["source_sha256"].items():
    assert hashlib.sha256((BACKEND / name).read_bytes()).hexdigest() == expected, name
cases = {case["id"]: case for case in json.loads((OUT / "cases.json").read_text())}
rows = [json.loads(line) for line in (OUT / "generations.jsonl").read_text().splitlines()]
assert len(rows) == len({row["attempt_id"] for row in rows}) == 60
assert Counter(row["case_id"] for row in rows) == Counter({case_id: 3 for case_id in cases})

audits = []
for row in rows:
    if not row["ok"]:
        continue  # Failed logical attempts remain failures in the overall denominator.
    case = cases[row["case_id"]]
    reports = case["history"]["reports"]
    parts = row["provider_responses"][-1]["candidates"][0]["content"]["parts"]
    raw = "".join(part.get("text", "") for part in parts if not part.get("thought"))
    selection = FeedbackSelection.model_validate_json(raw)
    choices = build_coaching_choices(case["history"])
    message = row["message"]
    assert choices.render(selection) == message
    fact = choices.observations[selection.motivational_observation]
    selected_action = choices.actions[selection.actionable_suggestion]
    first, second = message.split(". ", 1)
    first += "."
    assert first == fact.text
    assert format_checks(message)["pass"] and format_checks(message)["sentence_count"] == 2
    numbers = [float(value) for value in re.findall(r"\d+(?:\.\d+)?", first)]

    if selection.motivational_observation == "tracking_history":
        assert fact.category == "recording" and numbers == [len(reports)]
        fact_evidence = (
            f"The saved source contains {len(reports)} reports. This is one positive observation about "
            "recording effort, with no assertion of improvement, perfect grades, chronology, or actual driving habits."
        )
    elif selection.motivational_observation.startswith("strength_"):
        category = selection.motivational_observation.removeprefix("strength_")
        assert category in FIELDS and category == fact.category
        source = measured(reports, category)
        assert len(source) >= 2
        value = average(source, category)
        assert value >= 85 and numbers == [value, 100, len(source)]
        assert f"{FIELDS[category][1]} grade" in first
        assert set(fact.evidence["measuredReportIds"]) == {report["id"] for report in source}
        fact_evidence = (
            f"Independent arithmetic on source reports {sorted(report['id'] for report in source)} gives "
            f"{category} mean {value}/100 across {len(source)} measured positive-duration trips. "
            "The category is tracked in those modes. This is one grade-strength observation, without inventing improvement."
        )
    else:
        assert selection.motivational_observation.startswith("improved_")
        category, mode = selection.motivational_observation.removeprefix("improved_").rsplit("_", 1)
        assert category in FIELDS and fact.category == category and mode in {"regular", "navigation", "pocket"}
        all_dates = [day(report["reportDate"]) for report in reports if report["reportDate"] is not None]
        midpoint = min(all_dates) + (max(all_dates) - min(all_dates)) / 2
        dated = [report for report in measured(reports, category)
                 if report["drivingMode"] == mode and report["reportDate"] is not None]
        before = [report for report in dated if day(report["reportDate"]) <= midpoint]
        after = [report for report in dated if day(report["reportDate"]) > midpoint]
        assert len(before) >= 2 and len(after) >= 2
        earlier, recent = average(before, category), average(after, category)
        assert recent - earlier >= 1
        assert numbers == [earlier, recent, 100]
        assert f"in {mode} mode" in first and f"{FIELDS[category][1]} grade" in first
        assert set(fact.evidence["earlierReportIds"]) == {report["id"] for report in before}
        assert set(fact.evidence["recentReportIds"]) == {report["id"] for report in after}
        fact_evidence = (
            f"Independent source calendar-half arithmetic gives {category} means {earlier} then {recent}/100 "
            f"for {len(before)} earlier and {len(after)} recent {mode} trips. All are dated, measured, "
            "and positive-duration; undated reports and mode switches cannot supply this improvement. "
            "This is one supported positive grade-progress observation, not a relative-percent or lifetime claim."
        )

    action_id = selection.actionable_suggestion
    assert action_id in ACTIONS
    category, expected_text, action_meaning = ACTIONS[action_id]
    assert second == expected_text == selected_action.text and selected_action.category == category
    if category == "recording":
        positive = [report for report in reports if report["tripDurationMinutes"] > 0]
        assert len(positive) < 2
        if action_id == "check_driving_duration":
            assert not positive
        action_evidence = action_meaning + f" The source has {len(positive)} reports with driving time; no actual driving-strength claim is made."
    else:
        source = measured(reports, category)
        assert len(source) >= 2
        value = average(source, category)
        event_type = FIELDS[category][2]
        count = sum(event["violationType"] == event_type for report in source for event in report["violations"])
        weak_categories = set()
        for candidate in FIELDS:
            group = measured(reports, candidate)
            if len(group) >= 2 and (average(group, candidate) < 85 or any(
                event["violationType"] == FIELDS[candidate][2] for report in group for event in report["violations"]
            )):
                weak_categories.add(candidate)
        assert category in weak_categories if weak_categories else value >= 85
        action_evidence = (
            action_meaning + f" The source measures {category} in {len(source)} eligible trips, with grade mean "
            f"{value} and {count} recorded category events. This is "
            + ("one recommendation for a measured area to work on." if weak_categories else
               "one maintenance action for an evidenced strength, without inventing a weakness.")
        )
        if category in {"focus", "following_distance"}:
            action_evidence += " Only eligible modes and nonnull grades support the recommendation; unmeasured categories are not inferred."

    assessment = {
        "factualClaims": [{"quote": first, "evidence": fact_evidence, "verdict": "supported"}],
        "motivationalObservations": [{"quote": first, "evidence": fact_evidence, "supported": True}],
        "actionableSuggestions": [{"quote": second, "evidence": action_evidence, "supported": True}],
        "longTermRelevant": True,
        "longTermEvidence": (
            f"The selected observation and action concern the supplied {len(reports)}-report history or a measured "
            "category within it. The response makes no latest-trip-only, lifetime, zero-event-week, unique-overlap-duration, "
            "or unobserved-habit claim. With zero exposure the action concerns recording meaningful driving time."
        ),
        "plainText": True,
        "notes": "Direct Codex AI source review, without reading this run's automatic ratings. No independent human validation.",
    }
    Assessment.model_validate(assessment)
    audits.append({
        "attempt_id": row["attempt_id"],
        "reviewer": "Codex (AI source review; not an independent human reviewer)",
        "reviewed_at": datetime.now(timezone.utc).isoformat(),
        "generation_sha256": hashlib.sha256(message.encode()).hexdigest(),
        "review_method": "Direct source-report review and independent arithmetic, without consulting automatic ratings",
        "reason": fact_evidence + " " + action_evidence,
        "assessment": assessment,
    })

(OUT / "audit.jsonl").write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in audits), encoding="utf-8")
print(f"Source-reviewed {len(audits)} usable responses from {len(rows)} logical attempts.")
print("Generation errors:", sum(not row["ok"] for row in rows))
print("First-pass valid:", sum(row["first_pass_ok"] for row in rows), "repairs:", sum(row["repair_attempted"] for row in rows))
