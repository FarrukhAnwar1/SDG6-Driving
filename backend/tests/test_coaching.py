"""Check that every offered coaching choice is supported before Gemini sees it."""

from copy import deepcopy
from statistics import mean

import pytest

from app.schemas import FeedbackSelection
from app.services.coaching import CATEGORIES, build_coaching_choices
from app.services.suggestions import analyze_history
from tools.suggestion_benchmark_cases import build_cases, build_pilot_cases


@pytest.fixture
def cases():
    return {case.id: case for case in build_cases() + build_pilot_cases()}


def choices(case):
    return build_coaching_choices(analyze_history(case.reports))


def test_decline_and_unchanged_rates_cannot_be_selected_as_progress(cases):
    for name in ["02-declining", "11-less-exposure"]:
        options = choices(cases[name])
        assert list(options.observations) == ["tracking_history"]
        assert options.constraints["hasVerifiedImprovement"] is False
    assert set(choices(cases["02-declining"]).constraints["decliningGradeCategories"]) == set(CATEGORIES)


def test_mode_switch_does_not_create_improvement_choices(cases):
    options = choices(cases["10-mode-switch"])
    assert not options.constraints["hasVerifiedImprovement"]
    assert all(option.evidence["averageGrade"] == 92 for option in options.observations.values())
    assert set(options.actions) == {"reduce_notifications", "leave_space"}


def test_within_mode_comparisons_and_actual_zero_are_retained(cases):
    options = choices(cases["06-following-zero"])
    fact = options.observations["improved_following_distance_regular"]
    assert fact.evidence["earlierAverage"] == 10
    assert fact.evidence["recentAverage"] == 40
    assert fact.evidence["earlierReportIds"] == [1, 2, 3]
    assert options.actions["leave_space"].evidence["averageGrade"] == 25
    assert list(options.actions) == ["leave_space"]


@pytest.mark.parametrize("name,unmeasured", [
    ("08-navigation", {"focus"}),
    ("09-pocket", {"focus", "following_distance"}),
    ("17-legacy-null", {"following_distance"}),
])
def test_null_or_mode_excluded_categories_are_not_offered(cases, name, unmeasured):
    options = choices(cases[name])
    assert unmeasured <= set(options.constraints["unmeasuredCategories"])
    assert not any(option.category in unmeasured for option in options.observations.values())
    assert not any(option.category in unmeasured for option in options.actions.values())


def test_zero_exposure_only_offers_recording_encouragement_and_duration_check(cases):
    options = choices(cases["13-zero-exposure"])
    assert options.constraints["zeroDrivingExposure"]
    assert list(options.observations) == ["tracking_history"]
    assert list(options.actions) == ["check_driving_duration"]
    message = options.render(FeedbackSelection(
        motivational_observation="tracking_history", actionable_suggestion="check_driving_duration"))
    assert message == ("Saving these 6 trip reports gives you a useful record to reflect on. "
                       "Check that your next saved trip report includes driving time.")


def test_undated_report_cannot_supply_a_progress_comparison(cases):
    history = analyze_history(cases["16-undated"].reports)
    options = build_coaching_choices(history)
    assert options.constraints["undatedReportCount"] == 1
    assert list(options.observations) == ["tracking_history"]
    assert not options.constraints["hasVerifiedImprovement"]
    assert "earlier" not in options.observations["tracking_history"].text


def test_zero_duration_report_is_excluded_from_observed_grade_claims(cases):
    history = analyze_history(cases["03-strong"].reports)
    history = deepcopy(history)
    history["reports"][0]["tripDurationMinutes"] = 0
    history["reports"][0]["speedGrade"] = 0
    options = build_coaching_choices(history)
    fact = options.observations["strength_speed"]
    assert fact.evidence["averageGrade"] == 98
    assert fact.evidence["measuredReportIds"] == [2, 3, 4, 5, 6]
    assert "5 trips with driving time" in fact.text


def test_every_catalog_fact_matches_its_source_reports(cases):
    for case in cases.values():
        history = analyze_history(case.reports)
        rows = {row["id"]: row for row in history["reports"]}
        options = build_coaching_choices(history)
        for fact in options.observations.values():
            if fact.category == "recording":
                assert fact.evidence["reportCount"] == len(rows)
                continue
            field = CATEGORIES[fact.category][0]
            if "earlierReportIds" in fact.evidence:
                before = [rows[index] for index in fact.evidence["earlierReportIds"]]
                after = [rows[index] for index in fact.evidence["recentReportIds"]]
                assert len(before) >= 2 and len(after) >= 2
                assert {row["drivingMode"] for row in before + after} == {fact.evidence["drivingMode"]}
                assert all(row["reportDate"] is not None for row in before + after)
                assert fact.evidence["earlierAverage"] == round(mean(row[field] for row in before), 2)
                assert fact.evidence["recentAverage"] == round(mean(row[field] for row in after), 2)
                assert fact.evidence["recentAverage"] > fact.evidence["earlierAverage"]
            else:
                source = [rows[index] for index in fact.evidence["measuredReportIds"]]
                assert all(row["tripDurationMinutes"] > 0 and row[field] is not None for row in source)
                assert fact.evidence["averageGrade"] == round(mean(row[field] for row in source), 2)


def test_all_choices_render_bounded_two_sentence_feedback_and_reject_other_ids(cases):
    for case in cases.values():
        options = choices(case)
        for fact in options.observations:
            for action in options.actions:
                message = options.render(FeedbackSelection(
                    motivational_observation=fact, actionable_suggestion=action))
                assert len(message) <= 1200
                assert message.endswith(".")
                assert message.count(". ") == 1
                assert "guaranteed safe" not in message
                assert "Ignore previous instructions" not in message
        with pytest.raises(ValueError, match="approved choices"):
            options.render(FeedbackSelection(motivational_observation="perfect_score", actionable_suggestion="five_tips"))
