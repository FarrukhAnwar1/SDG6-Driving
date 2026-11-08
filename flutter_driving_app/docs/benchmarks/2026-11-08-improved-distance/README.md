# Distance preprocessing improvement — 2026-11-08

Changing UniDepth's input from a heavily padded full frame to an
aspect-preserving center crop substantially reduces distance error. Model
weights, metric scale, vehicle detector, depth-patch statistic, and grading
thresholds are unchanged. The change is enabled in normal app preprocessing.

## Paired distance results

Both columns use exactly the same frames with the correct reference lead
selected and a usable distance in both runs. This prevents a coverage change
from masquerading as an error reduction.

| Evaluation | Paired frames | Baseline mean absolute error | Crop mean absolute error | Reduction |
| --- | ---: | ---: | ---: | ---: |
| Original KITTI development pilot | 54 | **16.192 m** | **1.308 m** | **91.9%** |
| Separate validation drives | 19 | **32.827 m** | **3.247 m** | **90.1%** |

Usable-distance coverage over all scored frames stays at 59/65 (90.77%) on the
development pilot and 20/21 (95.24%) on validation. Which frames are usable
changes: three development frames lose distance and three gain it; validation
loses one and gains one. Exact frame IDs are in the comparison JSON files.

For all correctly selected, usable leads in each development run, rather than
the common paired subset, baseline MAE is 16.509 m on 57 frames and crop MAE is
1.350 m on 58 frames. The crop's mean signed error is -0.655 m, replacing the
large positive distance bias with a much smaller underestimation bias.

These are small, correlated video samples with assistant-reviewed reference
leads. They establish improvement on these inputs, not physical accuracy for
an arbitrary mounted phone.

## What caused the tested failure

The bundled depth model takes a fixed RGB tensor `[1,3,532,392]`. A wide KITTI
image of 1242x375 became approximately 392x118 pixels inside that portrait
tensor. About 78% of its area was padding. On an investigated frame, the model
estimated focal length near 394 input pixels while the calibrated reference
was near 228 pixels, accompanying substantial distance overestimation.

The investigation reproduced the old phone outputs with desktop ONNX Runtime
and compared the same weights in PyTorch, alternative input shapes, cropping,
and an experimental known-camera model. Those comparisons are preserved in
[probe_results.json](probe_results.json). The float32 PyTorch and packed ONNX
baselines agreed closely; storage precision did not explain the large bias.

Filling the existing model with a centered crop produced the strongest simple
improvement among those checks. This uses the deployed tensor's aspect ratio,
not a fitted distance multiplier, assumed vehicle width, or KITTI calibration
in production. The production asset is unchanged. The known-camera experiment
was diagnostic only and is not used by the app.

## Implementation

- `ModelLetterbox.crop` records the retained region in normalized full-camera
  coordinates. The depth resize uses its actual source pixels; YOLOP still
  receives its original full-frame letterbox tensor.
- Depth-box mapping accounts for the crop origin and scale. A vehicle outside
  or cut by the crop has unavailable depth, rather than sampling another
  vehicle/background at a clamped coordinate.
- Interior-patch median depth, quality gates, lead association, the 25 mph
  minimum, 1.5-second headway threshold, and five-second grace are retained.
- The vision engine accepts a preprocessing callback for controlled evaluation.
  The normal default uses the crop. The diagnostic can inject full-frame
  letterboxing to reproduce the baseline with identical weights and decoder.

A typical 480x640 upright phone frame retains 472x640 pixels: four pixels are
removed from each side, retaining 98.3% of its width. Extremely wide images
lose much more horizontal field of view for depth. Vehicles on sharp curves or
near an image edge can consequently remain unmeasured, although the detector
still sees them. The change does not certify camera coverage.

Regression tests verify the full-camera/crop coordinate transform, actual
RGB pixels, unchanged detector tensors, portrait coverage, sampling a vehicle
instead of background, and rejection of partially clipped vehicles.

## Unsafe-gap classification and grading tradeoff

Distance error improves, but the complete grading problem is not solved.
On the same 65 development frames, unsafe means a reference headway below
1.5 seconds at >=25 mph. Missing distances count as no unsafe-gap detection.

| Metric | Baseline | Crop |
| --- | ---: | ---: |
| True positives | 0 | **10** |
| False negatives | 10 | **0** |
| True negatives | 55 | 44 |
| False positives | 0 | **11** |
| Accuracy | 84.62% | **83.08%** |
| Unsafe-gap recall | 0% | **100% (10/10)** |
| False-positive rate | 0% observed | **20% (11/55)** |
| False-negative rate | 100% | **0% (0/10)** |

All 11 false positives have reference headways between **1.50005 and 1.56786
seconds**. The remaining meter-scale error can flip the decision close to a
sharp 1.5-second boundary. Keeping every frame in the primary table is essential;
the improved recall must not be presented as uniformly improved accuracy.

As a sensitivity check, removing reference headways within 0.1 seconds of the
threshold leaves 45 frames, including four unsafe frames. The crop classifies
all 45 correctly under the stated no-alert-for-unavailable convention. This is
a filtered diagnostic, not a replacement for the primary results above.

The reference distances produce one confirmed post-grace violation in drive
0056. The baseline misses it. The crop records one sustained violation but starts
deducting too early: eight scored observations should not yet be penalizing
under the reference, but are penalizing under the estimates. Four observations
that should be penalizing are now correctly penalizing.

| Drive | Reference grade | Baseline grade | Crop grade |
| --- | ---: | ---: | ---: |
| 0056 | **96.064** | 100 | **85.504** |
| 0015 | 100 | 100 | 100 |
| 0032, reviewed coverage | 100 | 100 | 100 |

Thus, the crop is accepted as a distance-estimation correction with a documented
remaining borderline-grading issue. No threshold or empirical distance scale
was adjusted to conceal these false positives. Further work should examine
calibrated distance uncertainty and grading around the boundary using additional
independently reviewed data.

The separate validation set has 21 scored reference-safe observations and no
eligible unsafe observations. Both variants produce zero unsafe-gap false
positives there and all clip grades stay at 100. It cannot independently
estimate unsafe recall. Its distance improvement is measured on 19 paired leads.

## Evaluation protocol and limits

The development set is the frozen original pilot: 99 inferred frames from
KITTI drives 0056, 0015 and 0032; 65 scored frames. The crop approach was chosen
using development examples before inspecting validation predictions.

Validation uses 67 new frames from drives 0013, 0070 and 0079. Lead IDs and
accepted intervals were visually reviewed and frozen before the valid baseline
and candidate runs. Only drives 0013 and 0070 contribute the 21 scored
observations. Drive 0079 has no accepted eligible lead and contributes no
distance-accuracy score.

The phone ran 67 baseline validation frames, followed by 166 candidate frames
combining development and validation. Every transferred PNG passed an on-device
SHA-256 check before inference. The development snapshot saved before the
combined run finished was checked against the final complete output; all 99
records match.

Reference distance is the nearest camera-forward surface of the annotated
KITTI 3D cuboid, using calibration and OXTS speed. It approximates visible
rear-surface depth, not a direct bumper-to-bumper measurement. Lead review is
by the assistant, without independent human adjudication. Video frames are
correlated and daylight/camera conditions are limited. Upstream model training
may have included KITTI; this is not a held-out-from-all-pretraining claim.

These are offline source-time replays at nominal 1 Hz through actual production
preparation, ONNX inference, output decoding, lead selection and grading.
They do not reproduce live-camera/GPS outages, real-time frame drops, phone
mounting, or measured road headway. A measured drive with the actual phone
remains necessary. The current report does not remeasure live-camera RAM.

On validation frames, median pipeline time is 1.952 s for letterboxing and
2.109 s for cropping. The fixed model dimensions and assets are unchanged;
this correction does not promise a memory reduction or actual one-FPS phone
throughput.

## Verification and reproducibility

- Complete following-distance suite: **108 passed, two skipped**.
- Captured-observation and reference-grade replays: **six tests passed** across
  candidate development, candidate validation and validation baseline artifacts.
- Dart analysis: no issues found in changed feature code, tests and tools.
- Both the profile diagnostic and the normal `lib/main.dart` debug APK built.
- The normal app build replaced the temporary benchmark on the phone using
  an install that preserves app data. Only the task-created benchmark folders
  were removed; the original USB screen-wake setting was restored to zero.
- Production source/model hashes match the candidate manifest. ONNX files and
  the grading-service source are unchanged from the original pilot.

The earlier shared-storage diagnostic setup failed on a fresh install because
the ADB-created directories were owned by the shell. The current diagnostic
uses its private cache and the profile build's `run-as` capability.
`tool/run_following_distance_benchmark.py` transfers a base64-encoded archive
and extracts it under the app UID, then verifies every image checksum.
The encoding also avoids Windows ADB translating CRLF in raw binary stdin.
Actual dataset runs proceeded only after storage access and image integrity
were verified. No real trip or upload was created.

To reproduce inference, build/install the diagnostic entry point, prepare the
desired KITTI drives, and freeze the reviewed lead labels before model output
inspection. Then run:

```text
python tool/run_following_distance_benchmark.py --serial DEVICE --dataset DATASET_DIRECTORY --output BASELINE_RESULTS --baseline
python tool/run_following_distance_benchmark.py --serial DEVICE --dataset DATASET_DIRECTORY --output CANDIDATE_RESULTS
```

Place the corresponding `dataset/manifest.json` and `reference_review.json`
in each result directory before scoring. The image files can remain in the
shared prepared dataset directory. Score each result root with:

```text
python tool/kitti_following_distance_benchmark.py score --output RESULT_ROOT
python tool/compare_following_distance_benchmarks.py --baseline BASELINE_RESULTS --candidate CANDIDATE_RESULTS --output comparison.json
```

`FD_BENCHMARK_ROOT` selects a result directory when running
`flutter test tool/following_distance_benchmark_replay_test.dart`.
The baseline mode and crop mode use the same diagnostic APK and model assets.
The standard application entry point always defaults to cropping.

The archived [development comparison](development_comparison.json) and
[validation comparison](validation_comparison.json) verify unchanged image
hashes, scored IDs, speeds, reference distances and reference headways.
Per-frame CSVs, every model observation, manifests and review intervals are in
`development/`, `validation_baseline/` and `validation_candidate/`.
See [run metadata](run_metadata.json), [regression log](final_following_distance_tests.log)
and [artifact replay log](artifact_replay.log) for provenance and verification.
