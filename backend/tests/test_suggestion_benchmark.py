"""Check the benchmark's oracle, scoring, and real SDK instrumentation offline."""

import json

import httpx
import pytest

from app.config import settings
from app.services import suggestions
from tools import benchmark_suggestions as benchmark
from tools.benchmark_suggestions import (
    RateLimiter, capture_production_response, corpus, format_checks, prepare, read_rows,
    quota_observations, score_response,
)
from tools.suggestion_benchmark_cases import build_cases, build_pilot_cases, reference_facts, verify_production_history


def assessment():
    return {
        "factualClaims": [{"quote": "Your grades improved", "verdict": "supported", "evidence": "60 to 90"}],
        "motivationalObservations": [{"quote": "Your grades improved", "supported": True, "evidence": "60 to 90"}],
        "actionableSuggestions": [{"quote": "Leave more space", "supported": True, "evidence": "Following grade is weakest"}],
        "longTermRelevant": True, "longTermEvidence": "Compares all six trips", "plainText": True, "notes": "",
    }


def test_twenty_distinct_reproducible_histories_have_checked_references():
    cases = build_cases()
    assert len(cases) == 20
    assert len({case.id for case in cases}) == 20
    assert corpus() == corpus()
    for case in cases:
        history = suggestions.analyze_history(case.reports)
        verify_production_history(case, history)
        for report in case.reports:
            for field in suggestions.GRADE_FIELDS:
                value = getattr(report, field)
                assert value is None or 0 <= value <= 100
            for event in report.violations:
                if report.driving_mode != "regular":
                    assert event.violation_type != "Focused Driving"
                if report.driving_mode == "pocket":
                    assert event.violation_type != "Adequate Following Distance"


def test_reference_exposes_raw_count_and_mode_switch_traps():
    cases = {case.id: case for case in build_cases()}
    less = reference_facts(cases["11-less-exposure"])
    assert less["earlier"]["violationsByType"]["Proper Speed"]["count"] == 16
    assert less["recent"]["violationsByType"]["Proper Speed"]["count"] == 4
    assert less["earlier"]["violationsByType"]["Proper Speed"]["countPerDrivingHour"] == 4
    assert less["recent"]["violationsByType"]["Proper Speed"]["countPerDrivingHour"] == 4
    switch = reference_facts(cases["10-mode-switch"])
    assert switch["earlier"]["averageGrades"]["overall_grade"] == 78.83
    assert switch["recent"]["averageGrades"]["overall_grade"] == 92
    assert switch["earlier"]["averageGrades"]["speed_grade"] == switch["recent"]["averageGrades"]["speed_grade"] == 92
    bad_history = suggestions.analyze_history(cases["11-less-exposure"].reports)
    bad_history["overall"]["averageGrades"]["speed_grade"] = 999
    with pytest.raises(ValueError, match="Reference mismatch"):
        verify_production_history(cases["11-less-exposure"], bad_history)


def test_scoring_requires_grounding_exactly_one_of_each_and_format():
    message = "Your grades improved. Leave more space before braking."
    review = assessment()
    assert score_response(message, review)["all_pass"]
    review["factualClaims"][0]["verdict"] = "unverifiable"
    assert not score_response(message, review)["grounded"]
    review = assessment()
    review["actionableSuggestions"].append({"quote": "Also check speed", "supported": True, "evidence": "Speed grade"})
    assert not score_response(message, review)["coaching_compliance"]
    review = assessment()
    review["factualClaims"] = []
    assert not score_response(message, review)["grounded"]
    assert not format_checks("Just one sentence.")["pass"]
    assert not format_checks("# Heading\nYour grades improved. Leave more space.")["pass"]


@pytest.mark.parametrize("decision", ["approve", "correct"])
def test_production_capture_and_report_distinguish_approval_from_correction(monkeypatch, tmp_path, decision):
    real_client = suggestions.genai.Client
    requests = []

    def handle(request):
        requests.append(json.loads(request.content))
        prompt = json.loads(requests[-1]["contents"][0]["parts"][0]["text"])
        text = json.dumps({"decision": decision, "message": prompt["draft"] if decision == "approve"
                          else prompt["draft"].replace("Check your", "On your next drive, check your")}
                          if "draft" in prompt else {"message":
                          "Your speed grades improved across your recorded trips. Check your speed against posted limits."})
        return httpx.Response(200, json={
            "modelVersion": "test-model-version",
            "usageMetadata": {"promptTokenCount": 100, "candidatesTokenCount": 20, "totalTokenCount": 120},
            "candidates": [{"finishReason": "STOP", "content": {"role": "model", "parts": [{"text":
                text}]}}],
        })

    def factory(**kwargs):
        kwargs["http_options"].client_args = {"transport": httpx.MockTransport(handle), "trust_env": False}
        return real_client(**kwargs)

    monkeypatch.setattr(settings, "gemini_api_key", "benchmark-test-key")
    monkeypatch.setattr(suggestions.genai, "Client", factory)
    with capture_production_response() as observed:
        message = suggestions.generate_feedback(corpus()[0]["history"])
    assert "speed grades improved" in message
    assert "speed against posted limits" in message
    assert len(requests) == 2
    assert requests[0]["generationConfig"]["maxOutputTokens"] == 4096
    assert observed.responses[0]["model_version"] == "test-model-version"
    assert observed.responses[0]["usage_metadata"]["total_token_count"] == 120
    assert [call["stage"] for call in observed.calls] == ["draft", "review"]
    assert observed.review_decision == decision
    assert (observed.draft_message == message) == (decision == "approve")
    assert "benchmark-test-key" not in json.dumps(observed.responses)
    manifest, cases = prepare(tmp_path, 1, "pilot")
    monkeypatch.setattr(RateLimiter, "acquire", lambda *args: (1000, 100))
    benchmark.generate(tmp_path, manifest, cases[:1])
    row, = read_rows(tmp_path / "generations.jsonl")
    assert row["review_decision"] == decision
    assert row["ok"] is True
    assert len(row["provider_calls"]) == 2
    assert (row["draft_message"] == row["message"]) == (decision == "approve")
    benchmark.report(tmp_path, manifest, cases)
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert summary["review_approved_drafts"] == int(decision == "approve")
    assert summary["review_corrected_drafts"] == int(decision == "correct")
    assert summary["draft_provider_calls"] == summary["review_provider_calls"] == 1
    assert summary["scored_responses"] == 0  # Approval alone is not a quality score.


def test_fresh_pilot_has_five_new_checked_histories():
    original = {row.id for row in build_cases()}
    pilot = build_pilot_cases()
    assert len(pilot) == 5
    assert not original.intersection(row.id for row in pilot)
    for case in pilot:
        verify_production_history(case, suggestions.analyze_history(case.reports))
    assert len(corpus("pilot")) == 5


def test_review_calls_are_throttled_and_throttle_does_not_consume_provider_budget(monkeypatch):
    class FakeTime:
        value = 0

        def time(self):
            return 1000 + self.value

        def perf_counter(self):
            return self.value

        def sleep(self, duration):
            self.value += duration

    clock = FakeTime()
    monkeypatch.setattr(benchmark, "time", clock)
    monkeypatch.setattr(suggestions, "monotonic", clock.perf_counter)
    real_client = suggestions.genai.Client
    requests = []

    def handle(request):
        requests.append(request)
        clock.value += 1  # Simulated real provider processing, not throttle time.
        prompt = json.loads(json.loads(request.content)["contents"][0]["parts"][0]["text"])
        text = json.dumps({"decision": "correct", "message":
                          "Your speed grades improved across your recorded trips. Check your speed against posted limits."}
                          if "draft" in prompt else {"message": "Your speed grade is 100. Drive better."})
        return httpx.Response(200, json={"candidates": [{"finishReason": "STOP",
            "content": {"role": "model", "parts": [{"text": text}]}}]})

    def factory(**kwargs):
        kwargs["http_options"].client_args = {"transport": httpx.MockTransport(handle), "trust_env": False}
        return real_client(**kwargs)

    monkeypatch.setattr(settings, "gemini_api_key", "benchmark-test-key")
    monkeypatch.setattr(settings, "gemini_timeout_seconds", 30)
    monkeypatch.setattr(suggestions.genai, "Client", factory)
    limiter = RateLimiter()
    with capture_production_response(limiter) as observed:
        assert suggestions.generate_feedback(corpus()[0]["history"])
    assert len(observed.calls) == 2
    assert observed.calls[1]["started_unix"] - observed.calls[0]["started_unix"] == 8
    assert observed.quota_wait_seconds == 7
    assert [request.extensions["timeout"]["read"] for request in requests] == [30, 29]
    assert clock.value - observed.quota_wait_seconds == 2
    assert observed.review_decision == "correct"
    assert "100" in observed.draft_message


def test_quota_accounting_includes_review_errors_and_calibration():
    generations = [{"provider_calls": [
        {"started_unix": 1000, "stage": "draft", "token_reservation": 100, "response": {"usage_metadata": {"total_token_count": 30}}},
        {"started_unix": 1008, "stage": "review", "token_reservation": 100, "error": {"provider_status": 429}},
    ]}]
    judgments = [{"started_unix": 1016, "token_reservation": 50, "provider_response": {"usage_metadata": {"total_token_count": 20}}}]
    calibration = [{"started_unix": 1024, "token_reservation": 50, "provider_response": {"usage_metadata": {"total_token_count": 10}}}]
    quota = quota_observations(generations, judgments, calibration)
    assert quota["generation_calls"] == 2
    assert quota["draft_calls"] == quota["review_calls"] == 1
    assert quota["scoring_calls"] == quota["calibration_calls"] == 1
    assert quota["total_calls"] == quota["max_calls_in_rolling_minute"] == 4
    assert quota["max_reserved_tokens_in_rolling_minute"] == 300
    assert quota["total_observed_tokens"] == 60
    assert quota["provider_errors"] == 1


def test_resume_rejects_changed_prompt_or_duplicate_attempts(tmp_path, monkeypatch):
    prepare(tmp_path, 3)
    prepare(tmp_path, 3)
    monkeypatch.setattr(suggestions, "SYSTEM_INSTRUCTION", "Different prompt")
    with pytest.raises(ValueError, match="configuration changed"):
        prepare(tmp_path, 3)
    path = tmp_path / "duplicates.jsonl"
    path.write_text('{"attempt_id":"a"}\n{"attempt_id":"a"}\n', encoding="utf-8")
    with pytest.raises(ValueError, match="Duplicate"):
        read_rows(path)


def test_manifest_freezes_suite_temperature_and_both_production_prompts(tmp_path, monkeypatch):
    manifest, cases = prepare(tmp_path, 3, "pilot")
    assert len(cases) == 5
    assert manifest["planned_generation_attempts"] == 15
    assert manifest["judge_temperature"] == 1
    assert manifest["planned_production_calls"] == 30
    assert manifest["generation_protocol"] == "natural_draft_and_ai_review_v1"
    assert (tmp_path / "source_snapshot/app/services/suggestions.py").exists()
    assert (tmp_path / "review_system_instruction.txt").read_text() == suggestions.REVIEW_INSTRUCTION
    with pytest.raises(ValueError, match="configuration changed"):
        prepare(tmp_path, 3, "regression")
    monkeypatch.setattr(suggestions, "REVIEW_INSTRUCTION", "Different reviewer")
    with pytest.raises(ValueError, match="review_prompt_sha256"):
        prepare(tmp_path, 3, "pilot")


def test_report_marks_failed_evaluator_controls_as_diagnostic(tmp_path):
    manifest, cases = prepare(tmp_path, 3, "pilot")
    (tmp_path / "calibration_summary.json").write_text(json.dumps({
        "controlled_examples": 7, "calls": 7, "passed": 6, "complete": True,
    }), encoding="utf-8")
    benchmark.report(tmp_path, manifest, cases)
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert summary["judge_control_checks_passed"] is False
    assert summary["judge_control_passes"] == 6
    assert summary["automated_ratings_status"] == "diagnostic_only_failed_or_missing_controls"
    assert "Automatic ratings are diagnostic" in (tmp_path / "README.md").read_text()
