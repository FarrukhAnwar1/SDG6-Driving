# Full natural-feedback regression: review method

This run freezes the current production writer/reviewer prompts and source from
commit 342a03c before running the same 20 synthetic histories three times each.
The 60 logical attempts require at most 120 production calls: one free-form draft
and one AI review/correction per attempt, sharing the production timeout. Errors
are retained, not replaced. No production prompt changes will be made in this run.

To conserve the supplied 500-request daily quota, this run does not call the
separate Gemini benchmark evaluator or repeat its seven control examples. The
earlier evaluator controls failed and its automatic ratings were diagnostic.
Instead Codex AI reviews each exact final paragraph against the saved synthetic
reports, independent reference calculations, and the frozen evaluation rubric.
No human validation is claimed. Production approve/correct decisions are pipeline
metadata and are not used as quality labels.

Each assessment extracts all claims about the driver's records and supports or
rejects them with actual evidence. It counts motivational observations and
independently executable actions by meaning. One cohesive observation may cover
related strengths; two independent behaviors count as two actions even within
one sentence. A goal such as 'drive better' is not a concrete action. Purpose
clauses for one coordinated maneuver are not extra actions. Prospective advice
is not treated as an assertion of a past cause. Consistent logging is valid
encouragement when improvement or measured strengths are not established.

Grounding checks include grade values/direction, modes, exposure, null versus
zero, missing weeks, undated reports, overlap, sample scope, and instruction-like
road strings. Review also checks exactly one supported motivational observation,
exactly one supported concrete action, relevance across the multi-trip sample,
and plain paragraph formatting. The existing benchmark scoring code combines
these assessments. audit.jsonl binds each assessment to the exact saved final
message with SHA-256; per-response evidence and empty human-review columns are
retained.

These histories were used during development, and three generations per history
are correlated. This is a regression benchmark, not an unseen-data accuracy
estimate, sensor validation, proof of road safety, or hallucination guarantee.
Latency includes both production calls and SDK setup, excluding injected quota
waits, database work, and Flutter/network end-to-end time.

The run completed with 60 attempts and 54 returned messages. All 54 final
messages received explicit Codex source review; no identical-text assessments
were reused. See FINDINGS.md, validation.json, and COMPARISON.md for outcomes.
The manifest's judge fields preserve harness defaults for the optional Gemini
judge; execution_plan.json records that it was not called.
