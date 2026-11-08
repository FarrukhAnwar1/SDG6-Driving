# Long-term suggestion benchmark

This tool evaluates the current production driving coach. The default regression
suite has **20 synthetic histories × 3 repetitions = 60 logical generations**.
The fresh pilot has **5 histories × 3 repetitions = 15 logical generations**.
No application database or real driving records are read. Gemini selects one
verified observation ID and one concrete action ID; Python renders the paragraph.

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

Each logical generation makes one production invocation, with at most one
corrective provider call for a complete but invalid selection. Provider errors,
blocked, truncated, and empty replies fail immediately. SDK automatic retries
remain disabled. Every actual call, including a repair, is recorded and throttled.
First-pass and final success are reported separately; repairs never replace the
saved first attempt. Restarting skips recorded logical attempts. A normal pilot
uses **37 calls** (15 coaching + 15 scoring + 7 calibration), at most **52** with
repairs. The full suite normally uses **127**, at most **187**. Do not run multiple
benchmark processes simultaneously.

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
  corpus hash, and planned call counts. No API key is saved.
- `cases.json`: production history payloads and separate reference facts.
- `generations.jsonl`: all attempted coaching calls, errors, response metadata,
  token usage, and generation latency, excluding throttle sleeps. `provider_calls`
  includes actual initial/repair calls; `first_pass_ok` and `repair_attempted`
  distinguish first-pass quality from recovery.
- `judgments.jsonl`: AI classifications, evidence, scoring errors, and usage.
- `calibration.jsonl` / `calibration_summary.json`: evaluator control checks,
  expected criteria, and actual judgments, separately from coaching samples.
- `source_snapshot/` and `quota_observations.json`: exact code used and observed
  call/token accounting, including repair and calibration calls.
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

Observation choices compare grades within the same driving mode and require at
least two dated positive-duration trips per period; strong grades and zero
violation counts are treated separately. Null/mode-excluded categories are not
offered. With zero exposure, the choices concern recording reports and obtaining
driving-time data. The full history still reaches Gemini; only approved choice
IDs can affect display text. This trades some wording variety for reliable
factual content and exactly one concrete behavior.

The original 60-generation benchmark is a frozen artifact. New runs use fresh
output directories and record their updated generation/evaluation protocol.
Pilot rates from five fresh histories are exploratory; they are not a matched
60-response before/after comparison with the original free-text system.

Latency includes production SDK setup and provider time. It excludes database
queries, the Flutter request, and rate-limit sleeps. The benchmark does not measure
phone RAM, sensor accuracy, or whether recorded grades reflect actual road safety.
Injected throttle sleeps also pause only the service's deadline clock during
instrumentation, so they cannot consume the production repair budget. The SDK's
real clocks/options and real network/provider time are unaffected.

The rubric-based approach follows Google's separation of groundedness and
instruction following in its [evaluation example](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/samples/generativeaionvertexai-create-evaluation-task).

Offline checks:

```bash
python -m pytest tests/test_coaching.py tests/test_suggestion_benchmark.py tests/test_suggestions.py -q -p no:cacheprovider
```
