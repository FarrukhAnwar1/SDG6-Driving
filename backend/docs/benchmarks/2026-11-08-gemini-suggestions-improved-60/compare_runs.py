"""Export the paired, descriptive comparison with the preserved original run."""

import json
from pathlib import Path

OUT = Path(__file__).resolve().parent
BASELINE = OUT.parent / "2026-11-08-gemini-suggestions"


def read(name, directory=OUT):
    return json.loads((directory / name).read_text(encoding="utf-8"))


old_manifest, new_manifest = read("manifest.json", BASELINE), read("manifest.json")
assert old_manifest["corpus_sha256"] == new_manifest["corpus_sha256"]
assert read("cases.json", BASELINE) == read("cases.json")
before_summary, after_summary = read("summary.json", BASELINE), read("summary.json")
before = {row["attempt_id"]: row for row in read("scored_responses.json", BASELINE)}
after = {row["attempt_id"]: row for row in read("scored_responses.json")}
assert set(before) == set(after) and len(before) == 60
assert all(before[key]["case_id"] == after[key]["case_id"] for key in before)

labels = {
    "grounded": "No unsupported factual claims",
    "motivation": "Exactly one supported motivational observation",
    "action": "Exactly one concrete, supported action",
    "coaching_compliance": "Both coaching requirements",
    "long_term": "Long-term relevance",
    "format": "Format",
    "all_pass": "All requirements",
}

comparison = {}
for metric, label in labels.items():
    old_pass = sum(bool(row.get("scores") and row["scores"][metric]) for row in before.values())
    new_pass = sum(bool(row.get("scores") and row["scores"][metric]) for row in after.values())
    assert old_pass == before_summary["passes"][metric]
    assert new_pass == after_summary["passes"][metric]
    improved = [key for key in before if not bool(before[key].get("scores") and before[key]["scores"][metric])
                and bool(after[key].get("scores") and after[key]["scores"][metric])]
    regressed = [key for key in before if bool(before[key].get("scores") and before[key]["scores"][metric])
                 and not bool(after[key].get("scores") and after[key]["scores"][metric])]
    comparison[metric] = {
        "label": label, "before_passes": old_pass, "after_passes": new_pass,
        "total_attempts": 60, "before_percent": round(100 * old_pass / 60, 2),
        "after_percent": round(100 * new_pass / 60, 2),
        "percentage_point_change": round(100 * (new_pass - old_pass) / 60, 2),
        "newly_passing_attempts": improved, "regressed_attempts": regressed,
    }

quota = read("quota_observations.json")
result = {
    "histories": 20, "attempts_per_history": 3, "attempts_per_run": 60,
    "identical_histories": True, "corpus_sha256": new_manifest["corpus_sha256"],
    "baseline_directory": str(BASELINE), "improved_directory": str(OUT),
    "metrics": comparison,
    "first_pass_all_requirements": after_summary["first_pass_all_requirements_passes"],
    "repair_attempts": after_summary["repair_attempts"],
    "generation_failures": after_summary["generation_failures"],
    "new_api_calls": quota["generation_calls"] + quota["scoring_calls"],
    "reused_calibration_records": quota["calibration_calls"],
    "new_calibration_calls": 0,
    "limits": quota,
    "generation_latency_seconds": {
        "before": before_summary["generation_latency_seconds"],
        "after": after_summary["generation_latency_seconds"],
    },
    "limitations": [
        "Primary scores are AI source review; independent human validation is outstanding.",
        "Original free-text Gemini generation is compared with Gemini selection plus Python-rendered verified text; this is a pipeline change, not a model-only comparison.",
        "The original evaluator protocol differs from the current diagnostic protocol. Raw automatic ratings are not the primary comparison.",
        "The current automatic evaluator passed only 6/7 reference controls; its new ratings remain diagnostic.",
        "These synthetic histories were used during development. This is regression evidence, not an unseen-data or real-world accuracy estimate.",
        "Three repetitions of each history are correlated; the percentages are descriptive.",
        "No failed coaching output is replaced or silently retried; repairs and first-pass results are recorded separately.",
    ],
}
(OUT / "comparison.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

lines = ["# Original and improved 60-generation comparison", "",
         "Both runs used exactly the same 20 synthetic histories, with three attempts per history.",
         "The table uses recorded AI source reviews. Independent human validation is outstanding.", "",
         "| Check | Original | Improved |", "| --- | ---: | ---: |"]
for metric in comparison.values():
    lines.append(f"| {metric['label']} | {metric['before_passes']}/60 ({metric['before_percent']}%) | "
                 f"{metric['after_passes']}/60 ({metric['after_percent']}%) |")
lines += ["", f"Improved first-pass all-requirements successes: {result['first_pass_all_requirements']}/60. "
          f"Validation repairs: {result['repair_attempts']}. Generation failures: {result['generation_failures']}.", "",
          f"New API calls: {result['new_api_calls']}; reused calibration records: {result['reused_calibration_records']} "
          "(no new calibration requests). See quota_observations.json for local call/token accounting.", "",
          "## Interpretation", ""]
lines += ["- " + note for note in result["limitations"]]
lines += ["", "The baseline and improved outputs, per-response evidence, source snapshots, and response hashes are retained. "
          "The improved source review is reproducible with review_regression.py, which validates numeric facts against "
          "the saved reports without consulting automatic ratings. Human-review columns in review.csv are empty.", ""]
(OUT / "COMPARISON.md").write_text("\n".join(lines), encoding="utf-8")
print(json.dumps({key: {"before": value["before_passes"], "after": value["after_passes"]}
                  for key, value in comparison.items()}, indent=2))
