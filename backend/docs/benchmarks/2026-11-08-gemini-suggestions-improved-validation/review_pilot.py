"""Reproduce the recorded Codex AI source review of this specific 15-run pilot.

These are AI assessments, not human labels. The review is constructed directly
from the source reports and the vetted single-action texts, without reading the
automatic evaluator's pilot ratings. Exact source/response hashes bind the review.
"""

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
from app.services.coaching import CATEGORIES, build_coaching_choices
from tools.benchmark_suggestions import Assessment


manifest = json.loads((OUT / "manifest.json").read_text())
for name, expected in manifest["source_sha256"].items():
    assert hashlib.sha256((BACKEND / name).read_bytes()).hexdigest() == expected, name
cases = {row["id"]: row for row in json.loads((OUT / "cases.json").read_text())}
rows = [json.loads(line) for line in (OUT / "generations.jsonl").read_text().splitlines()]
assert len(rows) == 15 and len({row["attempt_id"] for row in rows}) == 15
assert set(row["case_id"] for row in rows) == set(cases)
assert all(row["ok"] for row in rows)

action_review = {
    "monitor_speed": "One concrete monitoring behavior: check speed against posted limits; no speed-limit value or past cause is invented.",
    "brake_early": "One coordinated braking maneuver with timing/gradualness details, supported by the measured braking category; no independent second action.",
    "accelerate_gradually": "One concrete accelerator-input behavior, relevant to the measured acceleration category.",
    "steer_gradually": "One concrete steering-input behavior, relevant to the measured turning category.",
    "reduce_notifications": "One prospective action: enable Do Not Disturb before driving. This does not claim notifications caused past focus violations.",
    "leave_space": "One concrete spacing behavior, relevant to measured following-distance grades.",
    "check_driving_duration": "One report-quality action: check that the next saved report includes driving time; all source reports currently have zero exposure.",
}

audits = []
for row in rows:
    case = cases[row["case_id"]]
    history, reference = case["history"], case["reference"]
    parts = row["provider_responses"][-1]["candidates"][0]["content"]["parts"]
    raw_selection = "".join(part.get("text", "") for part in parts if not part.get("thought"))
    selection = FeedbackSelection.model_validate_json(raw_selection)
    choices = build_coaching_choices(history)
    assert choices.render(selection) == row["message"]
    fact = choices.observations[selection.motivational_observation]
    action = choices.actions[selection.actionable_suggestion]
    assert action.id in action_review
    message = row["message"]
    first, second = message.split(". ", 1)
    first += "."
    assert first == fact.text and second == action.text
    assert len(message) <= 1200 and message.count(". ") == 1
    assert not any(value in message for value in ["guaranteed safe", "perfect scores", "Ignore previous instructions"])
    numbers = [float(value) for value in re.findall(r"\d+(?:\.\d+)?", first)]

    if fact.id == "tracking_history":
        assert numbers == [reference["overall"]["reportCount"]]
        evidence = f"The source contains {len(history['reports'])} saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving."
    elif fact.id.startswith("strength_"):
        field = fact.category + "_grade"
        average = reference["overall"]["averageGrades"][field]
        source = [report for report in history["reports"]
                  if report["tripDurationMinutes"] > 0 and report.get(CATEGORIES[fact.category][0]) is not None]
        assert len(source) >= 2
        assert numbers == [average, 100, len(source)]
        assert average >= 85
        evidence = f"The independent reference gives {field} average {average} across {len(source)} measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement."
    else:
        assert fact.id == "improved_speed_regular" and row["case_id"] == "pilot-mixed"
        before = reference["earlier"]["averageGrades"]["speed_grade"]
        after = reference["recent"]["averageGrades"]["speed_grade"]
        assert before == 63 and after == 87
        assert numbers == [before, after, 100]
        assert {report["drivingMode"] for report in history["reports"]} == {"regular"}
        assert reference["earlier"]["reportCount"] == reference["recent"]["reportCount"] == 4
        evidence = "Independent reference means are 63 in the earlier four regular trips and 87 in the recent four regular trips. This supports one positive grade-progress observation within the same mode."

    if action.category == "recording":
        assert action.id == "check_driving_duration"
        assert all(report["tripDurationMinutes"] == 0 for report in history["reports"])
        action_evidence = action_review[action.id] + " No observed driving-habit claim is made."
    else:
        average = reference["overall"]["averageGrades"][action.category + "_grade"]
        assert average is not None
        action_evidence = action_review[action.id] + f" The independent average for this category is {average}."
        if row["case_id"] == "pilot-modes":
            assert action.category in {"focus", "following_distance"}
            regular = reference["byMode"]["regular"]["averageGrades"]
            assert regular["focus_grade"] == 40 and regular["following_distance_grade"] == 55
            action_evidence += " The relevant weakness is measured in three regular trips only; later pocket trips are not claimed to measure it."
        if row["case_id"] == "pilot-strong":
            assert average == 96
            action_evidence += " This is one maintenance action for an evidenced strength; it does not invent a weakness."

    assessment = {
        "factualClaims": [{"quote": first, "evidence": evidence, "verdict": "supported"}],
        "motivationalObservations": [{"quote": first, "evidence": evidence, "supported": True}],
        "actionableSuggestions": [{"quote": second, "evidence": action_evidence, "supported": True}],
        "longTermRelevant": True,
        "longTermEvidence": (
            f"The observation and selected behavior are grounded in the supplied {len(history['reports'])}-report history. "
            "The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern."
        ),
        "plainText": True,
        "notes": "Direct Codex AI source review, constructed without consulting automatic pilot ratings. No independent human validation.",
    }
    Assessment.model_validate(assessment)
    audits.append({
        "attempt_id": row["attempt_id"],
        "reviewer": "Codex (AI source review; not an independent human reviewer)",
        "reviewed_at": datetime.now(timezone.utc).isoformat(),
        "generation_sha256": hashlib.sha256(message.encode()).hexdigest(),
        "review_method": "Direct source-report review without reading the automatic pilot labels",
        "reason": evidence + " " + action_evidence,
        "assessment": assessment,
    })

(OUT / "audit.jsonl").write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in audits), encoding="utf-8")
print(f"Source-reviewed {len(audits)} pilot responses; every value, source scope, and single-action text matched.")
print("First-pass valid generations:", sum(row["first_pass_ok"] for row in rows), "of", len(rows))
for row in rows:
    print(row["attempt_id"], row["message"])
