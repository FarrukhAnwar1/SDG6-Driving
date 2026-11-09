# Long-term suggestion benchmark

This tool evaluates the current production driving coach. The default regression
suite has **20 synthetic histories × 3 repetitions = 60 logical generations**.
The fresh pilot has **5 histories × 3 repetitions = 15 logical generations**.
No application database or real driving records are read. Gemini writes a natural
draft, then a second call reviews it against the same driving history and either
approves it or returns a corrected paragraph. There is no sentence catalog.

From `backend`, using a Python environment with `requirements.txt` installed:

```bash
python tools/benchmark_suggestions.py run --output docs/benchmarks/my-gemini-run
```

For the smaller pilot:

```bash
python tools/benchmark_suggestions.py run --suite pilot --output docs/benchmarks/my-gemini-pilot
```

The key and model are read from the usual backend `.env`/environment settings.
Use a new output directory for a different experiment. For separate stages:

```bash
python tools/benchmark_suggestions.py prepare --output docs/benchmarks/my-gemini-run
python tools/benchmark_suggestions.py calibrate --output docs/benchmarks/my-gemini-run
python tools/benchmark_suggestions.py generate --output docs/benchmarks/my-gemini-run
python tools/benchmark_suggestions.py judge --output docs/benchmarks/my-gemini-run
python tools/benchmark_suggestions.py report --output docs/benchmarks/my-gemini-run
```

Use `--suite pilot` consistently for every stage of a pilot. `prepare` and
`report` are offline. `run` first checks the evaluator against seven AI-authored,
reference-controlled examples: supported advice, invented scores, vague actions,
multiple actions, coordinated braking, zero exposure, and prospective advice.
It stops before coaching generation if a calibration check fails. These checks
are not independent human calibration. The judge uses temperature **1.0** and a
fixed rubric clarifying the conservative criteria used for the baseline audit.
Separate stages can collect coaching outputs for explicit review when the
automatic evaluator is unsuitable. Reports prominently mark failed or missing
evaluator controls as **diagnostic only**; source-reviewed AI assessments remain
preliminary and separate from human validation. Preserve failed controls rather
than repeatedly resampling them until a passing result appears.

Each logical generation makes one production invocation with two provider calls:
draft and review/correction. They share the configured production timeout. A
malformed draft/review or a provider error fails the attempt; unreviewed drafts
are never returned. SDK automatic retries remain disabled. Every actual call is
recorded and throttled. Drafts, final messages, and review decisions are saved
separately. A review approval is not an independent accuracy score. Restarting
skips recorded logical attempts. A normal pilot uses **52 calls** (30 production
+ 15 scoring + 7 calibration). The full suite uses **187** (120 production + 60
scoring + 7 calibration). Use `--suite pilot --repeats 1` for a five-suggestion
pilot; `generate` alone then uses just ten calls. Do not run multiple benchmark
processes simultaneously.

The limiter permits at most eight calls per minute, at least eight seconds
between starts, and reserves UTF-8 input byte length plus the maximum output
tokens against a 150,000-token rolling minute budget. This deliberately leaves
headroom beneath the supplied 15 RPM / 250K TPM / 500 RPD limits. Other apps using
the same API key still consume the provider's shared quota. The tool does not
change billing or the configured model.

The reference cases cover improving/declining/strong/weak driving, opposing
category trends, actual zero grades, missing categories, navigation/pocket modes,
mode-switch artifacts, driving-exposure differences, missing weeks, zero exposure,
a latest-trip outlier, an undated report, overlapping events, an instruction-like
road name, and the six-trip/28-day boundary. A separate reference calculator
checks the production statistics before any request. The coach receives only its
normal production history, never the evaluation expectations.

Outputs include:

- `manifest.json`: model/settings, prompt and source hashes, package versions,
  corpus hash, both production prompt hashes, and planned call counts. No API key is saved.
- `cases.json`: production history payloads and separate reference facts.
- `generations.jsonl`: all attempted coaching calls, errors, response metadata,
  token usage, and generation latency, excluding throttle sleeps. `provider_calls`
  identifies draft and review calls. `draft_message` and `review_decision`
  preserve the original text and the reviewer's approve/correct verdict.
- `judgments.jsonl`: AI classifications, evidence, scoring errors, and usage.
- `calibration.jsonl` / `calibration_summary.json`: evaluator control checks,
  expected criteria, and actual judgments, separately from coaching samples.
- `source_snapshot/` and `quota_observations.json`: exact code used and observed
  call/token accounting, including both production stages and calibration calls.
- `summary.json`, `scored_responses.json`, and `README.md`: observed rates and
  per-response evidence.
- `review.csv`: scores/messages plus **empty** columns for later human review.

Factual grounding requires every extracted factual claim to be supported. The
coach must give exactly one supported motivational observation and one specific,
supported action, counted by meaning rather than by sentence. Long-term relevance
and formatting are scored separately. Overall success divides responses passing
every requirement by all recorded coaching attempts, including generation errors.
The other semantic rates use scored responses as their denominator; missing
judgments are disclosed rather than silently counted as passes.

These are **same-model AI judgments**, not independent human validation or a
guarantee against hallucinations. Repeated outputs from one history are correlated.
Use the saved evidence and empty human-review columns for independent validation.
An optional `audit.jsonl` can hold explicit assessment corrections with
`attempt_id`, `reviewer`, `reason`, and the complete `assessment` schema from
`judgments.jsonl`; any Codex audit must identify its reviewer as AI. Raw evaluator
judgments are retained when corrections are applied by `report`.

Both production prompts require supported encouragement and one concrete action.
They explain modes, exposure, missing data, and the difference between future
advice and invented past causes. The writer receives full reports, statistics,
and measured summaries by mode; the reviewer receives the same evidence plus
the draft. JSON validation checks shape and length. On approval the backend
returns the original draft, ignoring the reviewer's message; only a correction
uses replacement text. Semantic checks belong to the AI reviewer and can fail.
The benchmark's separate evaluator scores the final message; production review
verdicts alone are never counted as passing the quality requirements.

The original 60-generation benchmark is a frozen artifact. New runs use fresh
output directories and record their updated generation/evaluation protocol.
Pilot rates from five fresh histories are exploratory; they are not a matched
60-response before/after comparison with the original free-text system.

The [natural-feedback development check](../docs/benchmarks/2026-11-08-natural-review-pilot-v2/REVIEW_METHOD.md)
records the current two-stage flow, its five-history pilot, two reviewer probes,
and the earlier pilot's two-action miss. These are AI-reviewed development cases,
not a held-out test or a rerun of the 60-attempt benchmark.

Latency includes both production calls, SDK setup, and provider time. It excludes database
queries, the Flutter request, and rate-limit sleeps. The benchmark does not measure
phone RAM, sensor accuracy, or whether recorded grades reflect actual road safety.
Injected throttle sleeps also pause only the service's deadline clock during
instrumentation, so they cannot consume the shared production timeout. The SDK's
real clocks/options and real network/provider time are unaffected.

The rubric-based approach follows Google's separation of groundedness and
instruction following in its [evaluation example](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/samples/generativeaionvertexai-create-evaluation-task).

Offline checks:

```bash
python -m pytest tests/test_suggestion_benchmark.py tests/test_suggestions.py -q -p no:cacheprovider
```
