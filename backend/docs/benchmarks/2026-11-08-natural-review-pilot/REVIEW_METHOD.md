# Development pilot review

Five synthetic histories were generated once using the frozen source snapshot.
Production made ten API calls: five drafts and five reviews. All five reviewer
verdicts were approve. No separate Gemini evaluator or calibration was run.

Codex AI read each exact final message against the saved reports, reference
statistics, and existing benchmark rubric. Its claim, observation, and action
assessments are in audit.jsonl, bound to each message by SHA-256. There was no
human review. Counts describe these five exploratory outputs, not population
accuracy or an independent factual guarantee.

Four of five final messages met every criterion. The strong-history response
recommended both acceleration and braking maintenance; the production reviewer
missed this two-action error. This failed result is retained unchanged. Both
production prompts were subsequently clarified, and a separate run is saved in
../2026-11-08-natural-review-pilot-v2/. Those five histories are reused development
cases, not a held-out test set or a repeat of the original 60 attempts.

Latency includes both production API calls and SDK setup; injected quota waits,
database work, and Flutter/network round-trip time are excluded. Mean: 2.385s.
