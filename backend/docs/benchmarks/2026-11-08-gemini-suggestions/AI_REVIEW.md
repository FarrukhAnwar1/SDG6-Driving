# AI review rules

The initial evaluator is a separate request to the **same Gemini model** that
wrote the coaching messages. Codex also inspects the saved messages, source
reports, reference facts, and initial labels. Both reviewers are AI systems;
there has been **no independent human validation**. This is an exploratory
benchmark, not a preregistered study or a population accuracy estimate.

`judgments.jsonl` retains the original evaluator output. `audit.jsonl` records
the final Codex AI assessments and short reasons, including disagreements. The
main report uses the audited assessments. Its empty human-review columns are
provided for subsequent independent checking.

The following rules resolve recurring evaluator inconsistencies:

- Factual claims include numeric scores, trends, measured habits, dates, event
  counts/rates, and claims about causes. General prospective advice is not a
  statement that the driver already performed an action.
- A motivational observation is assessed as a whole. When a praise sentence
  combines genuine trip recording with invented perfect scores, selecting only
  the genuine subphrase does not make the complete observation supported.
- A valid action must describe a practical driver behavior: for example,
  monitoring speed, observing posted limits, leaving more space, anticipating
  stops, applying gradual brake pressure, or minimizing distractions. Merely
  naming a goal such as "reduce violations", "apply the same care", or "work on
  smoother braking habits" does not explain a behavior to perform. These
  borderline judgments are intentionally conservative and require human review.
- Recommended behaviors in independently executable categories are counted
  separately. Maintaining acceleration, braking, and attention involves multiple
  actions even when all are in one sentence. Timing and pressure details of one
  coordinated braking maneuver can form one suggestion. An explanatory purpose
  is not a second action.
- The assessment's `actionableSuggestions` list contains recommendation
  candidates. `supported: false` can mean a candidate is too vague to satisfy
  the practical-action requirement, even when its target category is supported
  by the data. The evidence field states which requirement failed.
- Long-term relevance means relevance to patterns in the supplied multi-trip
  sample. It does not require lifetime data. Advice about a dimension with
  repeated violations across eight trips remains relevant even when the latest
  trip is worse. Mentioning a recent setback does not itself invent a sustained
  decline.
- An undated report can support overall facts but cannot be assigned to an
  earlier or recent period. Ambiguous chronological claims are flagged
  conservatively. Missing weeks are unobserved, and zero driving duration does
  not demonstrate real driving habits merely because stored grades are high.
- "Steady progress" is a claim of improvement. Constant grades and unchanged
  exposure-adjusted violation rates do not establish improvement.

These definitions concern factual support, instruction following, and practical
specificity. They do not validate the underlying sensor measurements, grade
algorithm, advice safety, or real-world improvement in driving.
