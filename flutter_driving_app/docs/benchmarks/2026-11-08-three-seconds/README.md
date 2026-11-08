# Three-second following-distance grading — 2026-11-08

The production grader now treats headways below **3 seconds** as too close.
Exactly 3 seconds is safe. The existing **25 mph** minimum and **five-second
grace** remain. The gap must continue past grace before points are deducted.
The default observation deadline remains 1.5 seconds; it is independent of the
headway threshold. Severity remains `1 + (3 - headwaySeconds) / 0.5` points per
observed second after grace, with the grade clamped to 0–100 and no recovery.
A 2.5-second gap therefore costs 2 points/second and a 1-second gap costs 5.

This is a fresh run through the production Flutter preprocessing, ONNX models,
decoder, lead selector and grader on the connected **CPH2655 / Android 16** phone
in profile mode. All **166** transferred KITTI PNGs passed on-phone SHA-256 checks.
The same frozen images, lead IDs, distances, speeds and timestamps were reused.
Weights, depth crop and perception code are unchanged from the previous report.

## Unsafe-gap classification

There are **86 scored observations: 67 unsafe and 19 safe** under the new rule.
Development is the original 99-frame pilot (65 scored observations) from drives
0056, 0015 and 0032. Validation has 67 frames (21 scored observations) from drives
0013, 0070 and 0079. Drive 0079 has no accepted eligible reference lead. The
prior crop correction used development examples; no new distance scale or
model fitting was done for this threshold rerun.

A positive means estimated headway below three seconds. Missing/uncertain
distances count as no unsafe-gap detection; unsafe missing frames are false
negatives. All eligible scored frames remain in the primary metrics.


| Metric | Combined | Development | Validation |
| --- | ---: | ---: | ---: |
| Scored frames | 86 | 65 | 21 |
| Accuracy | 93.02% | 90.77% | 100.00% |
| Recall | 92.54% | 91.67% | 100.00% |
| False-positive rate | 5.26% | 20.00% | 0.00% |
| False-negative rate | 7.46% | 8.33% | 0.00% |
| Precision | 98.41% | 98.21% | 100.00% |
| True positives | 62 | 55 | 7 |
| True negatives | 18 | 4 | 14 |
| False positives | 1 | 1 | 0 |
| False negatives | 5 | 5 | 0 |


Usable-distance coverage is combined: 79/86 (91.86%); development: 59/65 (90.77%); validation: 20/21 (95.24%). Vehicle-detection recall at IoU >= 0.5 is 86/86.


## Actual grading after grace

These frame metrics compare the phone's `isPenalizing` signal with the same
policy applied independently to annotated distances and reviewed lead tracks.
They include continuity, tracking and grace, rather than just the instantaneous
three-second decision. They are frame metrics, not event-matched precision or
recall. A score of 100 does not establish camera coverage.


| Metric | Combined | Development | Validation |
| --- | ---: | ---: | ---: |
| Scored frames | 86 | 65 | 21 |
| Accuracy | 89.53% | 86.15% | 100.00% |
| Recall | 78.38% | 77.14% | 100.00% |
| False-positive rate | 2.04% | 3.33% | 0.00% |
| False-negative rate | 21.62% | 22.86% | 0.00% |
| Precision | 96.67% | 96.43% | 100.00% |
| True positives | 29 | 27 | 2 |
| True negatives | 48 | 29 | 19 |
| False positives | 1 | 1 | 0 |
| False negatives | 8 | 8 | 0 |


Reference tracks produce 6 confirmed violation streaks; the phone records 4. Counts alone do not establish that the streaks match.


| Drive | Reference grade | Phone grade |
| --- | ---: | ---: |
| 0056 | 1.151 | 0.000 |
| 0015 | 83.497 | 95.963 |
| 0032 | 97.583 | 99.699 |
| 0013 | 97.543 | 97.404 |
| 0070 | 100.000 | 100.000 |
| 0079 | 100.000 | 100.000 |


## Remaining errors

All five unsafe-gap false negatives have unavailable distances (`unreliable`).
The single false positive is drive 0032, frame 150: reference headway 3.058 s,
estimated headway 2.859 s. The full detector finds the annotated lead in all
86 scored frames, so detection recall alone would hide these distance/selection
coverage failures.

Post-grace grading also misses charged frames after a missing observation
resets continuity and the grace period. This explains why actual penalty recall
is lower than instantaneous unsafe-gap recall. The eight missed charging
frames and one extra charging frame are listed in `error_review.json` and
`scored_frames.csv`. The false positive for charging is a different frame
from the instantaneous false positive. No additional policy change was made
to alter those results.

## Distance error

Errors below require a usable prediction with the correct reference lead
selected (2D IoU >= 0.5). They exclude missing measurements and wrong-lead
selections; all-available distance metrics are also saved in each summary.


| Metric | Combined | Development | Validation |
| --- | ---: | ---: | ---: |
| Matched frames | 77 | 58 | 19 |
| Mean absolute error | 1.818 m | 1.350 m | 3.247 m |
| Root mean squared error | 2.389 m | 1.606 m | 3.906 m |
| Mean signed error | -1.087 m | -0.655 m | -2.406 m |
| Median absolute error | 1.404 m | 1.154 m | 2.897 m |


The fresh run was compared with all 166 archived improved-distance predictions. Maximum absolute distance change: 0.0 m. Perception outputs unchanged: True. The threshold changes grading decisions and severity; it does not improve distance estimates. Older 1.5-second classification scores use different positive labels and should not be compared as the same task.


Median inference-pipeline time was 2.108 seconds per frame. This is an offline replay using source timestamps at nominal 1 Hz, not live one-FPS throughput.


## Limits and verification

KITTI has no official following-distance violation labels. Reference lead IDs
were reviewed by the assistant, without independent human adjudication.
Reference distance is the nearest camera-forward surface of the annotated 3D
cuboid, not directly measured bumper-to-bumper distance. Frames are correlated
and represent a small selection of daytime drives. Upstream pretraining may
include KITTI. These figures do not establish general on-road accuracy for a
mounted phone. Live camera/GPS outages, frame drops, mounting conditions and
thermal behavior are outside this offline evaluation. Wilson intervals in the
JSON treat frames as independent and are optimistic for correlated video.

- Grading, voice-feedback and dashboard tests: **155 passed, 2 skipped**.
- Dart analyzer: **no issues found**.
- Scorer self-checks cover confusion denominators, both headway policies,
  grace, track changes, exact-threshold safety and the unchanged gap deadline.
- Artifact replay: **3 passed**. Checks verify the saved policy, every production selection
  and grade, and reference grades against the production Dart grader.
- Profile diagnostic and normal debug ARM64 APKs built successfully.

The normal application with the three-second rule was restored on the phone
without uninstalling or clearing app data. Only the diagnostic's private cache
was removed, and the original USB wake setting was restored.

## Artifacts and rerun

`accuracy_summary.json`, `scored_frames.csv`, `phone_predictions.jsonl`,
`manifest.json` and `reference_review.json` contain the complete combined run.
`development/` and `validation/` preserve separate scored splits.
`phone_dataset_events.jsonl`, `device_run.json`, `distance_consistency.json`,
`run_metadata.json` and the verification logs record runtime and provenance.
The prior benchmark directories remain unchanged.

With the local KITTI images available under the build dataset and the diagnostic
APK installed, run from the repository root:

```text
python3 flutter_driving_app/tool/run_following_distance_benchmark.py --serial DEVICE_SERIAL --dataset flutter_driving_app/build/following_distance_three_seconds/dataset --output flutter_driving_app/build/following_distance_three_seconds
```

From `flutter_driving_app`, using the benchmark Python environment:

```text
python tool/kitti_following_distance_benchmark.py score --headway-seconds 3 --output build/following_distance_three_seconds
```

The scorer defaults to the current Dart headway constant and rejects phone
records explicitly tagged with a different threshold. For the Dart artifact
replay, set `FD_BENCHMARK_ROOT=build/following_distance_three_seconds` and run
`flutter test tool/following_distance_benchmark_replay_test.dart`.
