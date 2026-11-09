# Gemini long-term suggestion benchmark

Status: complete

5 synthetic histories × 3 repetitions; 15 generation attempts recorded.
Production model: `gemini-3.5-flash-lite`. Judge: `gemini-3.5-flash-lite`.
Suite: `pilot`. Judge temperature: 1.0.
Scoring is AI evaluation; no independent human reviewers participated.

Evaluator reference controls: 6/7 passed. Automatic ratings are diagnostic because controls failed or are missing. Any audited scores below are separately identified AI review, not human validation.

| Measure | Passes | Denominator | Observed rate |
| --- | ---: | ---: | ---: |
| No unsupported factual claims | 15 | 15 scored responses | 100.0% |
| Exactly one supported motivational observation | 15 | 15 scored responses | 100.0% |
| Exactly one supported actionable suggestion | 15 | 15 scored responses | 100.0% |
| Both coaching elements | 15 | 15 scored responses | 100.0% |
| Long-term relevance | 15 | 15 scored responses | 100.0% |
| Format | 15 | 15 scored responses | 100.0% |
| All requirements, including successful generation | 15 | 15 attempts | 100.0% |

Generation failures: 0. Scored: 15/15 usable responses.
First-pass valid generations: 15/15. Validation repair attempts: 0. Actual coaching calls: 15.
All requirements before any repair: 15/15 (100.0%).

Scoring calls: 15 (separate from the coaching generation attempts). Codex AI audits: 15.

Controlled AI-authored judge calibration calls: 7; see calibration_summary.json. These are not coaching generations or human labels.

Generation latency (seconds): {'mean': 1.105, 'median': 1.044, 'p95_nearest_rank': 1.6159}. Rate-limit sleeps are excluded.

## Method

The benchmark invokes the current production `analyze_history` and `generate_feedback` functions directly. Every history is eligible (at least six dated reports spanning 28 days). A separate reference calculator checks the numeric summaries before any network call. Case expectations/reference answers are provided only to the evaluator, never to the coach.

The limiter permits at most eight calls per minute with at least eight seconds between starts, and reserves UTF-8 input byte length plus the output-token cap against a 150,000-token rolling minute budget. This leaves headroom under the supplied 15 RPM / 250K TPM / 500 RPD limits. Only run one benchmark process at a time. Other clients using the key are outside this limiter.

Each logical generation invokes production once. Production may make one corrective request for a complete but invalid ID selection; provider errors, blocked, truncated, and empty replies are not retried. Every actual provider call, including a repair, is recorded and throttled. Benchmark throttle sleeps are excluded from the service deadline clock and measured latency; the SDK's real clocks/options are unchanged. First-pass and final success are reported separately. Errors are retained. Resuming skips recorded logical attempts. A crash during an unrecorded provider call cannot be distinguished from a call that never reached the provider.

The response schema permits exactly one approved observation ID and one approved action ID. The backend verifies membership and renders the two vetted sentences; the model cannot supply display prose or numeric claims. Improvement choices compare grades within the same mode with at least two measured trips per period. Null/untracked categories and zero-exposure habit claims are excluded. The full original history remains available to the selector. Source snapshots, hashes, prompts, and package versions are saved.

Quota observations are in `quota_observations.json`. `review.csv` contains empty human-review columns; no human validation is claimed.

No-unsupported-claims scores require every extracted factual claim to be supported. Motivational and actionable elements are counted by meaning and must each be supported and relevant. General prospective driving advice is not treated as a claim that the driver already did something. Overall success requires every rubric item and valid production output; failed or unscored attempts are not successes.

## Limitations

- Synthetic histories; no validation of sensor or grading accuracy.
- Gemini selects approved observation/action IDs; Python renders vetted text. This is a hybrid system, with less wording variety than free-text generation.
- Same-model AI judge; any Codex audit is also AI, not independent human validation.
- Repeated generations of one history are correlated; observed percentages are descriptive.
- Latency covers production generation including SDK setup, not database or Flutter/network end-to-end latency.
- Sentence counts use a punctuation heuristic; semantic counts are judged by meaning.

A passing result does not prove the model never hallucinates. The included review.csv has empty human-rating columns for later independent review. Raw coach outputs, evaluator evidence, source/prompt hashes, package versions, and any AI audit corrections are retained beside this report.

## Implementation and interpretation

The backend now has a history-specific catalog of verified observations and
single concrete actions. Gemini selects two scalar IDs; Python verifies those
IDs and assembles the approved texts into the same public message field. No
model-written numeric claims, extra actions, or free-text substitutions reach
the display. The tradeoff is reduced wording variation. All original report
fields still reach the selector.

The original [60-generation baseline](../2026-11-08-gemini-suggestions/README.md)
is preserved. This pilot uses **five fresh histories and three repetitions each**,
covering decline, strong maintenance, opposing trends, a mode switch, and zero
exposure. Its 15/15 source-reviewed result is exploratory and is not a matched
60-response before/after accuracy comparison or a general guarantee.

The evaluator passed only **6/7 reference controls** after a documented rubric
revision. It still rejected a valid 28-day comparison for lacking lifetime data.
Consequently its ratings are diagnostic, retained in `judgments.jsonl` and
[raw_ai_summary.json](raw_ai_summary.json). A previous 5/7 control attempt is
preserved separately. The failed controls were not resampled until passing.
`calibration_provenance.json` records reuse of the same 6/7 control requests after
a report-only change; copied records are not extra API requests.

The diagnostic evaluator passed 14/15 pilot responses for grounding. In its lone
failure it emitted an empty factual-claim list for the correct statement about
six saved reports. The scorer conservatively fails an empty claim list. The
separate source review verified that six reports were present.

The displayed preliminary scores use **direct Codex AI source review of all 15
messages**, constructed without consulting the automatic pilot labels. The
review checked the numeric values, source scope, approved ID rendering, and one
coordinated action per message. `review_pilot.py` reproduces these specific checks;
`audit.jsonl` contains evidence and response hashes. This is AI review, without
independent human validation. The CSV's human-rating columns remain empty.

Total validation usage across both evaluator-control revisions and the pilot was **44 actual API calls** (14 controls, 15 coaching, 15 diagnostic scoring). The observed maximum was **8 calls per rolling minute**, with no provider/quota errors. See [all_improvement_calls.json](all_improvement_calls.json); reused calibration records are counted once.

[Backend verification](verification.json): **308 passed, 6 skipped**; skipped tests
require an optional disposable MySQL database. Tests cover the authenticated
API contract, all choices across 25 synthetic histories, independent fact checks,
mode/missing-data safeguards, invalid selections, bounded repair, shared timeout,
and quota accounting. The pilot needed **zero repairs**; repair behavior was
verified with mocked provider responses. One dependency deprecation warning is
recorded in the verification file.

## Per-response evidence

### pilot-declining/r1

Saving these 6 trip reports gives you a useful record to reflect on. On your next drives, check your speed against posted limits.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Saving these 6 trip reports gives you a useful record to reflect on. — The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving. One concrete monitoring behavior: check speed against posted limits; no speed-limit value or past cause is invented. The independent average for this category is 82.0.

### pilot-strong/r1

Your recorded speed grade averaged 96 out of 100 across 6 trips with driving time, giving you a strength to build on. On your next drives, check your speed against posted limits.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Your recorded speed grade averaged 96 out of 100 across 6 trips with driving time, giving you a strength to build on. — The independent reference gives speed_grade average 96.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The independent reference gives speed_grade average 96.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement. One concrete monitoring behavior: check speed against posted limits; no speed-limit value or past cause is invented. The independent average for this category is 96.0. This is one maintenance action for an evidenced strength; it does not invent a weakness.

### pilot-mixed/r1

Across your recorded trips in regular mode, your average speed grade rose from 63 to 87 out of 100 between the earlier and recent periods, showing progress in that category. When approaching a stop, begin slowing early enough to brake gradually.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Across your recorded trips in regular mode, your average speed grade rose from 63 to 87 out of 100 between the earlier and recent periods, showing progress in that category. — Independent reference means are 63 in the earlier four regular trips and 87 in the recent four regular trips. This supports one positive grade-progress observation within the same mode.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 8-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: Independent reference means are 63 in the earlier four regular trips and 87 in the recent four regular trips. This supports one positive grade-progress observation within the same mode. One coordinated braking maneuver with timing/gradualness details, supported by the measured braking category; no independent second action. The independent average for this category is 77.5.

### pilot-modes/r1

Your recorded speed grade averaged 94 out of 100 across 6 trips with driving time, giving you a strength to build on. Before your next drive, enable Do Not Disturb to reduce notifications.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Your recorded speed grade averaged 94 out of 100 across 6 trips with driving time, giving you a strength to build on. — The independent reference gives speed_grade average 94.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The independent reference gives speed_grade average 94.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement. One prospective action: enable Do Not Disturb before driving. This does not claim notifications caused past focus violations. The independent average for this category is 40.0. The relevant weakness is measured in three regular trips only; later pocket trips are not claimed to measure it.

### pilot-zero/r1

Saving these 6 trip reports gives you a useful record to reflect on. Check that your next saved trip report includes driving time.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Saving these 6 trip reports gives you a useful record to reflect on. — The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving. One report-quality action: check that the next saved report includes driving time; all source reports currently have zero exposure. No observed driving-habit claim is made.

### pilot-declining/r2

Saving these 6 trip reports gives you a useful record to reflect on. On your next drives, check your speed against posted limits.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Saving these 6 trip reports gives you a useful record to reflect on. — The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving. One concrete monitoring behavior: check speed against posted limits; no speed-limit value or past cause is invented. The independent average for this category is 82.0.

### pilot-strong/r2

Your recorded speed grade averaged 96 out of 100 across 6 trips with driving time, giving you a strength to build on. On your next drives, check your speed against posted limits.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Your recorded speed grade averaged 96 out of 100 across 6 trips with driving time, giving you a strength to build on. — The independent reference gives speed_grade average 96.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The independent reference gives speed_grade average 96.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement. One concrete monitoring behavior: check speed against posted limits; no speed-limit value or past cause is invented. The independent average for this category is 96.0. This is one maintenance action for an evidenced strength; it does not invent a weakness.

### pilot-mixed/r2

Across your recorded trips in regular mode, your average speed grade rose from 63 to 87 out of 100 between the earlier and recent periods, showing progress in that category. When approaching a stop, begin slowing early enough to brake gradually.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Across your recorded trips in regular mode, your average speed grade rose from 63 to 87 out of 100 between the earlier and recent periods, showing progress in that category. — Independent reference means are 63 in the earlier four regular trips and 87 in the recent four regular trips. This supports one positive grade-progress observation within the same mode.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 8-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: Independent reference means are 63 in the earlier four regular trips and 87 in the recent four regular trips. This supports one positive grade-progress observation within the same mode. One coordinated braking maneuver with timing/gradualness details, supported by the measured braking category; no independent second action. The independent average for this category is 77.5.

### pilot-modes/r2

Your recorded speed grade averaged 94 out of 100 across 6 trips with driving time, giving you a strength to build on. Before your next drive, enable Do Not Disturb to reduce notifications.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Your recorded speed grade averaged 94 out of 100 across 6 trips with driving time, giving you a strength to build on. — The independent reference gives speed_grade average 94.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The independent reference gives speed_grade average 94.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement. One prospective action: enable Do Not Disturb before driving. This does not claim notifications caused past focus violations. The independent average for this category is 40.0. The relevant weakness is measured in three regular trips only; later pocket trips are not claimed to measure it.

### pilot-zero/r2

Saving these 6 trip reports gives you a useful record to reflect on. Check that your next saved trip report includes driving time.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Saving these 6 trip reports gives you a useful record to reflect on. — The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving. One report-quality action: check that the next saved report includes driving time; all source reports currently have zero exposure. No observed driving-habit claim is made.

### pilot-declining/r3

Saving these 6 trip reports gives you a useful record to reflect on. On your next drives, check your speed against posted limits.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Saving these 6 trip reports gives you a useful record to reflect on. — The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving. One concrete monitoring behavior: check speed against posted limits; no speed-limit value or past cause is invented. The independent average for this category is 82.0.

### pilot-strong/r3

Your recorded speed grade averaged 96 out of 100 across 6 trips with driving time, giving you a strength to build on. On your next drives, check your speed against posted limits.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Your recorded speed grade averaged 96 out of 100 across 6 trips with driving time, giving you a strength to build on. — The independent reference gives speed_grade average 96.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The independent reference gives speed_grade average 96.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement. One concrete monitoring behavior: check speed against posted limits; no speed-limit value or past cause is invented. The independent average for this category is 96.0. This is one maintenance action for an evidenced strength; it does not invent a weakness.

### pilot-mixed/r3

Across your recorded trips in regular mode, your average speed grade rose from 63 to 87 out of 100 between the earlier and recent periods, showing progress in that category. When approaching a stop, begin slowing early enough to brake gradually.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Across your recorded trips in regular mode, your average speed grade rose from 63 to 87 out of 100 between the earlier and recent periods, showing progress in that category. — Independent reference means are 63 in the earlier four regular trips and 87 in the recent four regular trips. This supports one positive grade-progress observation within the same mode.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 8-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: Independent reference means are 63 in the earlier four regular trips and 87 in the recent four regular trips. This supports one positive grade-progress observation within the same mode. One coordinated braking maneuver with timing/gradualness details, supported by the measured braking category; no independent second action. The independent average for this category is 77.5.

### pilot-modes/r3

Your recorded speed grade averaged 94 out of 100 across 6 trips with driving time, giving you a strength to build on. Before your next drive, enable Do Not Disturb to reduce notifications.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Your recorded speed grade averaged 94 out of 100 across 6 trips with driving time, giving you a strength to build on. — The independent reference gives speed_grade average 94.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The independent reference gives speed_grade average 94.0 across 6 measured positive-duration reports. The text reports this average as a strength, without calling it perfect or claiming improvement. One prospective action: enable Do Not Disturb before driving. This does not claim notifications caused past focus violations. The independent average for this category is 40.0. The relevant weakness is measured in three regular trips only; later pocket trips are not claimed to measure it.

### pilot-zero/r3

Saving these 6 trip reports gives you a useful record to reflect on. Check that your next saved trip report includes driving time.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Saving these 6 trip reports gives you a useful record to reflect on. — The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving.
- Motivational observations: 1; actionable suggestions: 1.
- The observation and selected behavior are grounded in the supplied 6-report history. The message neither generalizes a latest-trip outlier nor claims lifetime evidence. Zero exposure is handled as a recording/data-quality pattern.

Codex AI audit: The source contains 6 saved reports. The observation praises logging only and makes no claim of improved or reliable actual driving. One report-quality action: check that the next saved report includes driving time; all source reports currently have zero exposure. No observed driving-habit claim is made.

