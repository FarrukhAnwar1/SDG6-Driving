# Matched 60-attempt regression comparison

All three runs use the same 20 synthetic histories, three attempts each. Scores are AI source review; no human validation.

| Measure | Original free-form | Fixed-choice pipeline | Natural draft + AI review |
| --- | ---: | ---: | ---: |
| Completed suggestions | 60/60 | 60/60 | 54/60 |
| No unsupported factual claims | 55/60 scored | 60/60 scored | 51/54 scored |
| Exactly one supported motivational observation | 56/60 scored | 60/60 scored | 50/54 scored |
| Exactly one supported concrete action | 38/60 scored | 60/60 scored | 52/54 scored |
| Both coaching requirements | 36/60 scored | 60/60 scored | 48/54 scored |
| Long-term relevance | 59/60 scored | 60/60 scored | 54/54 scored |
| Format | 60/60 scored | 60/60 scored | 54/54 scored |
| All requirements, including successful completion | 35/60 | 60/60 | 48/60 |
| Mean completed-suggestion latency | 1.372s | 1.221s | 2.651s |

Current run: 115 production API calls; no separate Gemini grading or calibration calls. All failed attempts remain in the denominator.
Completion latency includes both current production calls and SDK setup, excluding quota sleeps, database work, and Flutter/network end-to-end time. Its denominator is 54 completed messages; the harness's general generation-latency field also includes failed attempts.

The fixed-choice system restricts prose to prewritten verified sentences. The current system writes freely and adds a same-model reviewer/corrector; review can miss errors. These are pipeline changes, not a controlled model-only experiment.

The histories were used during development and the three repetitions are correlated. Semantic classifications, especially qualitative praise, are Codex AI judgments and require independent human review. The blank human-review columns and claim-by-claim evidence remain available. See validation.json for every failure.
