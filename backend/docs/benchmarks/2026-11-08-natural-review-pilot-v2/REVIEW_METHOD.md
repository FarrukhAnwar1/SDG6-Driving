# Natural feedback with AI review: development validation

The production flow now uses a free-form Gemini draft followed by one separate
Gemini reviewer/corrector call using the same full driving evidence. Only the
reviewed paragraph is returned. The fixed sentence/choice catalog was removed.
Both stages share a 30-second budget; automatic retries are disabled.

The final five-history development pilot produced five usable suggestions.
Codex AI source review found all five met the factual-grounding, one motivational
observation, one concrete action, long-term relevance, and formatting rubric.
Production approved four drafts and corrected one. Mean completion latency for
both calls was **2.458 seconds**, excluding injected quota waits, database work,
and Flutter/network round-trip time. Each complete suggestion uses two API calls.

These five cases were reused after prompt refinement; they are not held out and
are not a rerun of the original 60 attempts. Source review is AI assessment, not
human validation or proof against hallucinations. The production review verdict
is recorded separately and is not used as an accuracy label. No separate Gemini
scorer or seven-case evaluator calibration was run.

The first five-history pilot is preserved in
../2026-11-08-natural-review-pilot/. It passed 4/5 in Codex AI review: the reviewer
missed a two-action acceleration/braking recommendation. Both prompts were then
clarified for that case. The final run and the earlier failure remain separate.

Two additional reviewer-only development probes checked the known two-action
draft and fabricated speed progress from 91 to 100. Both received corrected
messages, checked against the saved records by Codex AI. They are not included
in the five-suggestion quality denominator or the seven evaluator controls. Raw
responses and explicit source-review evidence are in reviewer_checks.jsonl.

All work in this change used **22 live API calls**: 20 for the two five-history
runs plus two reviewer probes. Calls were paced below the supplied limits. The
combined accounting and test outcomes are saved in validation.json.

Full backend checks: **318 passed, 6 optional database tests skipped**. After the
prompt clarification, the service/benchmark checks passed again: **97 passed**.

Manifest/source snapshots freeze each run's code and prompts. audit.jsonl binds
each explicit Codex judgment to its exact final message with a SHA-256 hash.
source_review.py records those judgments for this exact run; it is not a general
automated classifier. check_reviewer.py reproduces the two reviewer probes from
the backend directory using the configured key (and skips recorded probe IDs).
review.csv leaves human-review columns blank for later independent review.
