# Review method and limits

This is the requested rerun of the **same 20 original synthetic histories**, three
attempts per history. Parsed case data and the corpus hash match the preserved
original benchmark exactly. The production/evaluator source hashes also match
the previously tested improved pilot; their snapshots are retained here.

The product has changed from free-text Gemini generation to Gemini selection of
one verified observation and one approved action, followed by Python rendering.
The comparison measures that feedback pipeline change. It is not a model-only
comparison and gives up some wording variation for factual and action-count
control.

Primary ratings are **direct Codex AI source review**, not independent human
validation. `review_regression.py` checks each saved display message against the
actual selected IDs and the exact approved text. It then independently reads the
saved source reports to verify:

- Report counts for encouragement about recording history.
- Grade means, measured-trip counts, and eligible driving modes for strengths.
- Earlier/recent means using the raw report-date calendar midpoint, with at least
  two measured dated trips in each period and the same mode on both sides.
- Exclusion of zero driving exposure, null grades, and mode-untracked categories
  from driving-performance evidence. Genuine measured zero scores remain valid.
- One specific, independently executable action tied to a measured category, or
  one recording/data-quality action when measurements are insufficient.
- Two plain-text sentences, bounded length, source scope, and absence of invented
  causes, road conditions, safety guarantees, or unsupported chronological claims.

The action texts were reviewed for meaning: timing and gradualness details of a
single coordinated braking maneuver count as one suggestion. Notification-setting
advice is prospective and does not assert that notifications caused past events.
Each assessment records evidence and a hash of the exact displayed response.
The direct assessments were constructed without consulting this run's automatic
ratings.

The same-model evaluator previously passed only **6/7 controlled examples**. Its
unchanged configuration and failed control records are reused with provenance,
without fresh API requests or resampling until passing. The new automatic ratings
are retained only as diagnostics. The evaluator protocol/temperature differs
from the original benchmark; raw automatic scores are not the primary paired
comparison. Original source-reviewed baseline labels are preserved rather than
retrospectively changed.

The regression histories were used during development. Three outputs for one
history are correlated, so observed rates do not establish population accuracy,
unseen-data performance, or real-world road safety. Stored grades are treated as
the source of truth; this does not validate the sensors or grading algorithm.
Independent human review remains outstanding; the human-rating CSV columns are
empty.

Every logical generation, actual initial/repair provider call, error, and latency
is saved. First-pass quality and final quality are separate. Failed coaching
attempts are not replaced. All new generation and diagnostic calls use the
configured Flash Lite model and the existing eight-call-per-minute limiter with
a conservative 150,000-token reservation budget. Reused historical calibration
records are identified separately from new API calls.
