# Observed regression results

The run used the same 20 synthetic histories three times each with unchanged
production code/prompts. Gemini made 115 actual API calls: 60 drafts and 55
reviews. Five draft calls returned provider 503 errors. One otherwise complete
review returned approve but changed the draft wording, so production rejected it.
All six failed attempts remain in the 60-attempt denominator; none was replaced.

Of 54 returned messages, explicit Codex AI source review classified 51 as fully
grounded, 50 as containing exactly one supported motivational observation, and
52 as containing exactly one concrete supported action. All 54 met long-term
relevance and format checks. Forty-eight met all criteria: 48/54 returned
messages (88.89%), or 48/60 attempts (80%).

The six semantic failures were:

- 04-weak/r1: unsupported attention/turning praise from moderate grades.
- 04-weak/r2: neutral consistency at weak scores without supported encouragement.
- 04-weak/r3: calling recorded focus grades of 65 strong.
- 07-focus/r2 and /r3: asking for attention without a sufficiently concrete action.
- 14-missing-weeks/r2: ambiguous management/attention praise beyond the evidence.

These are explicit AI semantic judgments, including qualitative wording that
needs independent human review. The three grounding misses concern qualitative
praise, not fabricated numerical scores. Each assessment and its evidence is
saved in audit.jsonl and scored_responses.json; review.csv leaves human fields
blank. No separate Gemini scoring or evaluator-calibration calls were made.

Among completed messages, the reviewer approved 30 drafts and corrected 24.
Those verdicts are pipeline metadata, not independent accuracy scores. The
54 completed suggestions averaged 2.651 seconds, with median 2.433s and
nearest-rank p95 4.1445s. This includes both production calls and SDK setup,
excluding benchmark quota waits, database queries and Flutter end-to-end time.
The harness's separate all-attempt latency mean (2.613s) includes failures.

The matched comparison is in COMPARISON.md. Original free-form results passed
35/60, the fixed-choice pipeline passed 60/60, and the current natural draft plus
review passed 48/60 in their recorded AI source reviews. These are different
pipelines and review methods on reused development histories, not a controlled
model-only or unseen-data accuracy estimate. Production code and prompts were
not changed during this benchmark.

Run from backend to reproduce the offline arithmetic/report from saved outputs:

```bash
python docs/benchmarks/2026-11-08-natural-review-60/finalize_results.py
```

The judgments are already saved explicit Codex AI assessments; this command does
not independently regenerate them or call Gemini. Source snapshots and exact
message hashes are verified before reporting.
