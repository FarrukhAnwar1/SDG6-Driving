# Original and improved 60-generation comparison

Both runs used exactly the same 20 synthetic histories, with three attempts per history.
The table uses recorded AI source reviews. Independent human validation is outstanding.

| Check | Original | Improved |
| --- | ---: | ---: |
| No unsupported factual claims | 55/60 (91.67%) | 60/60 (100.0%) |
| Exactly one supported motivational observation | 56/60 (93.33%) | 60/60 (100.0%) |
| Exactly one concrete, supported action | 38/60 (63.33%) | 60/60 (100.0%) |
| Both coaching requirements | 36/60 (60.0%) | 60/60 (100.0%) |
| Long-term relevance | 59/60 (98.33%) | 60/60 (100.0%) |
| Format | 60/60 (100.0%) | 60/60 (100.0%) |
| All requirements | 35/60 (58.33%) | 60/60 (100.0%) |

Improved first-pass all-requirements successes: 60/60. Validation repairs: 0. Generation failures: 0.

New API calls: 120; reused calibration records: 7 (no new calibration requests). See quota_observations.json for local call/token accounting.

## Interpretation

- Primary scores are AI source review; independent human validation is outstanding.
- Original free-text Gemini generation is compared with Gemini selection plus Python-rendered verified text; this is a pipeline change, not a model-only comparison.
- The original evaluator protocol differs from the current diagnostic protocol. Raw automatic ratings are not the primary comparison.
- The current automatic evaluator passed only 6/7 reference controls; its new ratings remain diagnostic.
- These synthetic histories were used during development. This is regression evidence, not an unseen-data or real-world accuracy estimate.
- Three repetitions of each history are correlated; the percentages are descriptive.
- No failed coaching output is replaced or silently retried; repairs and first-pass results are recorded separately.

The baseline and improved outputs, per-response evidence, source snapshots, and response hashes are retained. The improved source review is reproducible with review_regression.py, which validates numeric facts against the saved reports without consulting automatic ratings. Human-review columns in review.csv are empty.

Diagnostic grading returned 57/60 usable ratings; 3 request errors are retained separately. All 60 coaching calls succeeded. New API calls: 120; quota errors: 0. See validation.json and raw_ai_summary.json.
