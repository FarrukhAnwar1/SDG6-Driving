# Gemini long-term suggestion benchmark

Status: complete

5 synthetic histories × 1 repetitions; 5 generation attempts recorded.
Production model: `gemini-3.5-flash-lite`. Judge: `gemini-3.5-flash-lite`.
Suite: `pilot`. Judge temperature: 1.0.
Scoring is AI evaluation; no independent human reviewers participated.

Evaluator reference controls: 0/7 passed. Automatic ratings are diagnostic because controls failed or are missing. Any audited scores below are separately identified AI review, not human validation.

| Measure | Passes | Denominator | Observed rate |
| --- | ---: | ---: | ---: |
| No unsupported factual claims | 5 | 5 scored responses | 100.0% |
| Exactly one supported motivational observation | 5 | 5 scored responses | 100.0% |
| Exactly one supported actionable suggestion | 4 | 5 scored responses | 80.0% |
| Both coaching elements | 4 | 5 scored responses | 80.0% |
| Long-term relevance | 5 | 5 scored responses | 100.0% |
| Format | 5 | 5 scored responses | 100.0% |
| All requirements, including successful generation | 4 | 5 attempts | 80.0% |

Generation failures: 0. Scored: 5/5 usable responses.
Reviewer approved drafts: 5. Reviewer corrected drafts: 0. Actual coaching calls: 10 (5 draft + 5 review).
These are the production reviewer's decisions, not independent measurements of draft accuracy. The quality scores above evaluate final messages separately.

Scoring calls: 0 (separate from the coaching generation attempts). Codex AI audits: 5.

Controlled AI-authored judge calibration calls: 0; see calibration_summary.json. These are not coaching generations or human labels.

Generation latency (seconds): {'mean': 2.385, 'median': 2.26, 'p95_nearest_rank': 2.6388}. Rate-limit sleeps are excluded.

## Method

The benchmark invokes the current production `analyze_history` and `generate_feedback` functions directly. Every history is eligible (at least six dated reports spanning 28 days). A separate reference calculator checks the numeric summaries before any network call. Case expectations/reference answers are provided only to the evaluator, never to the coach.

The limiter permits at most eight calls per minute with at least eight seconds between starts, and reserves UTF-8 input byte length plus the output-token cap against a 150,000-token rolling minute budget. This leaves headroom under the supplied 15 RPM / 250K TPM / 500 RPD limits. Only run one benchmark process at a time. Other clients using the key are outside this limiter.

Each logical generation invokes production once: one free-form draft call, followed by one reviewer/corrector call using the full history. Only a successfully reviewed message is returned. Provider errors, malformed, blocked, truncated, and empty replies are not retried. Every actual provider call is recorded and throttled. Benchmark throttle sleeps are excluded from the service deadline clock and measured latency; the SDK's real clocks/options are unchanged. Drafts, review decisions, final messages, and errors are retained. Resuming skips recorded logical attempts. A crash during an unrecorded provider call cannot be distinguished from a call that never reached the provider.

The writer produces natural prose; the reviewer independently checks factual support, exactly one motivational observation, and exactly one concrete action, then approves the draft verbatim or supplies a corrected paragraph. The same model performs both stages, so review does not guarantee correctness. Structured JSON validates shape, not factual truth. Source snapshots, hashes of both production prompts and the evaluator prompt, and package versions are saved.

Quota observations are in `quota_observations.json`. `review.csv` contains empty human-review columns; no human validation is claimed.

No-unsupported-claims scores require every extracted factual claim to be supported. Motivational and actionable elements are counted by meaning and must each be supported and relevant. General prospective driving advice is not treated as a claim that the driver already did something. Overall success requires every rubric item and valid production output; failed or unscored attempts are not successes.

## Limitations

- Synthetic histories; no validation of sensor or grading accuracy.
- Two calls to the same model draft and review free-form feedback. Review can miss errors; its approval/correction is not an independent quality score.
- Same-model AI judge; any Codex audit is also AI, not independent human validation.
- Repeated generations of one history are correlated; observed percentages are descriptive.
- Latency covers both production calls including SDK setup, not database or Flutter/network end-to-end latency.
- Sentence counts use a punctuation heuristic; semantic counts are judged by meaning.

A passing result does not prove the model never hallucinates. The included review.csv has empty human-rating columns for later independent review. Raw coach outputs, evaluator evidence, source/prompt hashes, package versions, and any AI audit corrections are retained beside this report.

## Per-response evidence

### pilot-declining/r1

Keeping these trip records gives you a useful starting point to work from as you review your driving habits over time. Begin checking your speedometer more frequently to monitor your pace on future trips.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Keeping these trip records gives you a useful starting point to work from as you review your driving habits over time. — Six dated, positive-duration reports span 35 days. Every category declines from 91 to 73 between the calendar halves. Logging encouragement makes no claim of improvement.
- Motivational observations: 1; actionable suggestions: 1.
- Six dated, positive-duration reports span 35 days. Every category declines from 91 to 73 between the calendar halves. Logging encouragement makes no claim of improvement.

Codex AI audit: Explicit review of final free-form text against frozen synthetic reports, numerical reference facts, and the benchmark rubric. Production approvals are not used as quality labels.

### pilot-strong/r1

Your recorded trips show consistent high-level performance across all evaluated driving categories over the past several weeks. Keep maintaining steady acceleration and smooth braking habits on every upcoming trip.

Scores: `{"grounded": true, "motivation": true, "action": false, "coaching_compliance": false, "long_term": true, "format": true, "all_pass": false}`

- supported: Your recorded trips show consistent high-level performance across all evaluated driving categories over the past several weeks. — Six positive-duration regular reports span 35 days; every measured category is 96 on every report. This describes consistent strength, not improvement or guaranteed safety.
- Motivational observations: 1; actionable suggestions: 2.
- Six positive-duration regular reports span 35 days; every measured category is 96 on every report. This describes consistent strength, not improvement or guaranteed safety.

Codex AI audit: Explicit review of final free-form text against frozen synthetic reports, numerical reference facts, and the benchmark rubric. Production approvals are not used as quality labels.

### pilot-mixed/r1

Your speed grades have shown steady improvement across your recorded trips. Begin slowing earlier when approaching a stop to smooth out your braking on future drives.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Your speed grades have shown steady improvement across your recorded trips. — Eight positive-duration regular trips have speed grades 54, 60, 66, 72, 78, 84, 90, 96; calendar-half means increase from 63 to 87. Braking declines from 87.5 to 67.5.
- Motivational observations: 1; actionable suggestions: 1.
- Eight positive-duration regular trips have speed grades 54, 60, 66, 72, 78, 84, 90, 96; calendar-half means increase from 63 to 87. Braking declines from 87.5 to 67.5.

Codex AI audit: Explicit review of final free-form text against frozen synthetic reports, numerical reference facts, and the benchmark rubric. Production approvals are not used as quality labels.

### pilot-modes/r1

Your driving records show consistent strength in maintaining steady speed and smooth acceleration across your trips. For your next drive, try increasing the space between your vehicle and the car ahead when following in traffic.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Your driving records show consistent strength in maintaining steady speed and smooth acceleration across your trips. — All six positive-duration reports have speed and acceleration grades of 94, across three regular and three pocket trips. This is one cohesive strength observation, not a claim that mode-driven overall grades improved.
- Motivational observations: 1; actionable suggestions: 1.
- All six positive-duration reports have speed and acceleration grades of 94, across three regular and three pocket trips. This is one cohesive strength observation, not a claim that mode-driven overall grades improved.

Codex AI audit: Explicit review of final free-form text against frozen synthetic reports, numerical reference facts, and the benchmark rubric. Production approvals are not used as quality labels.

### pilot-zero/r1

Thank you for consistently keeping your trip records updated. Please check that your next saved trip includes recorded driving time.

Scores: `{"grounded": true, "motivation": true, "action": true, "coaching_compliance": true, "long_term": true, "format": true, "all_pass": true}`

- supported: Thank you for consistently keeping your trip records updated. — Six dated reports are stored, but every report has zero driving duration. Encouragement concerns logging only and does not treat stored grades of 93 as demonstrated driving habits.
- Motivational observations: 1; actionable suggestions: 1.
- Six dated reports are stored, but every report has zero driving duration. Encouragement concerns logging only and does not treat stored grades of 93 as demonstrated driving habits.

Codex AI audit: Explicit review of final free-form text against frozen synthetic reports, numerical reference facts, and the benchmark rubric. Production approvals are not used as quality labels.
