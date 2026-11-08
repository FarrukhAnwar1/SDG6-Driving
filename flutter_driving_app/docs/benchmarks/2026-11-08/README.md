# Following-distance phone memory and KITTI pilot — 2026-11-08

The production following-distance pipeline used about **964 MiB median PSS**
while processing the live rear camera on the connected CPH2655. In a separate
KITTI pilot it **missed all 10 unsafe-gap frames** among 65 scored frames.
The resulting 84.6% classification accuracy equals the safe-frame prevalence;
it does not demonstrate successful unsafe-following detection.

These measurements use the repository's existing models and Dart services.
No production model, threshold, distance scale, lead-selection rule, or grading
rule was changed or tuned. The new tools and this report add evaluation only.

## Phone memory

Device: CPH2655, Android 16 / API 36, ARM64. The diagnostic was built in Flutter
**profile** mode and launched without an attached debugger. ONNX Runtime used
the production CPU provider, four intra-op threads, one inter-op thread, and
sequential YOLOP and UniDepth execution.

Android `dumpsys meminfo` was sampled approximately once per second for 150
seconds. Stable-phase summaries omit the first three seconds of each phase;
steady vision also starts five seconds after the first completed inference.

| Diagnostic state | Samples | Median PSS | Observed maximum PSS | Median RSS |
| --- | ---: | ---: | ---: | ---: |
| Flutter idle, camera/models unopened | 9 | 166.86 MiB | 168.51 MiB | 312.11 MiB |
| Rear camera and preview, no models | 15 | 195.81 MiB | 202.18 MiB | 344.75 MiB |
| Rear camera and production vision/monitoring/grading | 81 | **963.82 MiB** | **1,022.91 MiB** | **1,111.25 MiB** |

Steady vision PSS ranged from 946.17 to 1,022.91 MiB; its 95th percentile was
999.25 MiB. Median PSS increased **768.01 MiB** over camera-only operation.
Median native-heap PSS during steady vision was 788.54 MiB.

This is total memory attributed to the diagnostic process, including Flutter,
camera buffers, native inference, and the production vision services. It is not
an isolated weights-only measurement or the complete signed-in dashboard's
memory usage. The maximum is a **sampled** maximum, not proof of the true
instantaneous peak. A 90-second active run does not establish long-term memory
stability, thermal behavior, or behavior on other devices.

[Android's PSS definition](https://developer.android.com/tools/dumpsys#meminfo)
accounts proportionally for memory shared with other processes. MiB means
1,048,576 bytes; the 963.82 MiB median corresponds to about 1.01 decimal GB.

The run completed 28 live-camera analyses in its 90-second vision phase.
Median processing time was 3.139 s; mean was 3.140 s, and the maximum was
3.358 s. The app's one-FPS limit is a scheduling cap. Actual observed throughput
in this run was approximately 0.31 processed frames/s.

The diagnostic used synthetic 90 mph GPS to exercise monitoring without
creating a trip. Camera images were neither saved nor uploaded. The temporary
diagnostic package was absent before this task and was removed afterward;
the original USB screen-wake setting was restored.

Artifacts: [memory summary](memory_summary.json),
[raw memory samples, gzip](memory_samples.jsonl.gz),
[phase/inference event log](memory_events.jsonl).

## Dataset and reference definition

The source is the official [KITTI raw dataset](https://www.cvlibs.net/datasets/kitti/raw_data.php):
left color camera `image_02`, synchronized/rectified frames, OXTS GPS/IMU speed,
camera/Velodyne calibration, and 3D vehicle tracklets. The pilot uses these
three 2011-09-26 sequences, sampled every tenth source frame (nominally 1 Hz):

| Drive | Inferred frames | Scored frames | Unsafe reference frames | Safe reference frames |
| --- | ---: | ---: | ---: | ---: |
| 0056 | 30 | 30 | 10 | 20 |
| 0015 | 30 | 17 | 0 | 17 |
| 0032 | 39 | 18 | 0 | 18 |
| Total | **99** | **65** | **10** | **55** |

The sequences were deliberately selected after inspecting annotation/speed
availability to obtain safe and unsafe examples. This is a diagnostic sample,
not a random test set or an official benchmark split.

KITTI does not directly label ego-lane leads or following-distance violations.
Preparation proposed leads geometrically using the nearest annotated vehicle
within a +/-1.5 m lateral corridor. The assistant then reviewed contact sheets
for all 99 sampled frames and recorded explicit lead IDs and accepted intervals
in [reference_review.json](reference_review.json) **before running inference**.
The review is not independently human-adjudicated. The manifest's geometric
candidate fields are retained for provenance; the explicit review ranges
define the primary scored reference. Ambiguous transition frames were excluded.

Scored frames require speed >=25 mph and a reviewed, fully annotated lead.
Reference distance is the nearest camera-forward Z surface of that vehicle's
annotated 3D cuboid, transformed with KITTI calibration. This approximates
visible rear-surface depth, and is not a direct bumper-to-bumper measurement.
Speed is the magnitude of OXTS horizontal north/east velocity, converted to mph.

Unsafe means `referenceDistanceMeters / speedMetersPerSecond < 1.5`.
Exactly 1.5 seconds is safe under the app's configured grading rule. A positive
prediction requires a usable production distance and a predicted headway below
1.5 seconds. Missing or uncertain distances count as no unsafe-gap detection
in the primary confusion matrix. Availability is also reported separately.

No model was trained or tuned using these labels. The upstream pretrained
components may have encountered KITTI, so this is not evidence of performance
on a dataset held out from all upstream training.

## Unsafe-gap classification results

| Reference / prediction | Predicted unsafe | No unsafe-gap detection |
| --- | ---: | ---: |
| Reference unsafe | **TP = 0** | **FN = 10** |
| Reference safe | **FP = 0** | **TN = 55** |

| Metric | Formula | Result |
| --- | --- | ---: |
| Accuracy | (TP+TN)/N | **84.62% (55/65)** |
| Unsafe-gap recall | TP/(TP+FN) | **0% (0/10)** |
| False-positive rate | FP/(FP+TN) | **0% observed (0/55)** |
| False-negative rate | FN/(FN+TP) | **100% (10/10)** |
| Precision | TP/(TP+FP) | Undefined: no positive predictions |
| F1 | 2TP/(2TP+FP+FN) | 0 |
| Usable-distance coverage | Usable predictions / scored frames | **90.77% (59/65)** |

Restricting scoring to the 59 usable predictions gives 83.05% accuracy and
still 0% recall / 100% false-negative rate. Thus, missing coverage alone does
not explain the unsafe misses. All 10 unsafe frames had usable distances.

As a boundary-sensitivity check, excluding reference headways within 0.1 s of
the threshold leaves 45 frames, including four unsafe frames. All four are
still missed. The original geometric/straight-road subset within the reviewed
intervals has 51 scored frames and seven unsafe frames; all seven are missed.

There are only 10 unsafe video frames, primarily from one sustained episode,
not 10 independent unsafe events. Zero observed false positives does not
establish a zero population false-positive rate. Exploratory Wilson intervals
are recorded in the JSON; they assume independent frames and are optimistic
for correlated video. Larger, independently reviewed, diverse drives are
needed for defensible deployment accuracy estimates.

## Vehicle detection and distance error

YOLOP produced a confidence >=0.25 detection overlapping every reviewed lead
at IoU >=0.5: **65/65 reference leads detected**. This measures reference-lead
box recall, not following-distance recall or detector precision for all traffic.
Of the 59 usable selected distances, 57 match the reviewed lead at IoU >=0.5.

For those 57 matching selections:

| Distance metric against annotated cuboid surface | Result |
| --- | ---: |
| Mean absolute error | **16.51 m** |
| Root mean squared error | 17.51 m |
| Mean signed error | **+16.51 m** |
| Median absolute error | 15.16 m |
| Mean absolute relative error | 63.27% |
| Within a factor of 1.25 of the reference | 2/57 (3.51%) |

All 57 errors were overestimates. The observed failure is substantial depth
overestimation on these inputs; the experiment does not isolate its underlying
cause. KITTI's wide camera images and camera setup differ from a mounted phone.

For example, drive 0056 frame 190 has an annotated surface distance of
**18.03 m** and a reference headway of **1.337 s**. The app estimated **31.66 m**
and **2.348 s**, so its configured rule treated the gap as safe.

## Actual grading behavior

The phone ran the unchanged `VehicleDistanceEstimator` and
`FollowingDistanceGradingService` using the source timestamps and speeds.
Recorded predictions produced **100/100 for all three clips**.

Feeding the reviewed reference distances into the production Dart grader yields:

| Drive | Grade using reviewed reference distances | Actual estimated-distance grade |
| --- | ---: | ---: |
| 0056 | **96.0643** | **100** |
| 0015 | 100 | 100 |
| 0032, within reviewed coverage | 100 | 100 |

The reference distances produce **one confirmed post-grace violation**, which
the estimated-distance run misses. Four scored source-time observations should
be actively deducting points after the five-second grace period. The app was
actively deducting at zero of those observations. For active-penalty state,
TP=0, FN=4, FP=0, TN=61: accuracy 93.85%, recall 0%, observed FPR 0%, FNR 100%.
These are per-observation penalty-state rates; an event-level false-positive
rate is not defined by this sample.

The 99 frames were processed sequentially in an **offline source-time replay**
on the phone. The production preparation, model inference, postprocessing,
lead selection and grading were exercised. This dataset mode bypasses the live
camera coordinator and its GPS freshness/watchdog checks. It does not simulate
real-time frame dropping, phone mounting, GPS outages, or camera interruptions.
Median model-pipeline time for dataset frames was 2.048 s; mean was 1.922 s.
Nominal 1 Hz source-time replay therefore does not claim actual 1 Hz phone
throughput. The separate live-camera memory run measures real runtime cadence.

## Reproduction and verification

The measurements and archived artifacts below describe the original run.
Current diagnostic tools use app-private cache storage; the later
[preprocessing comparison](../2026-11-08-improved-distance/README.md) documents
the updated `run-as` transfer workflow, which avoids fresh-install external
storage permission failures. The original numerical results are unchanged.

The tools are in `tool/`:

- `following_distance_benchmark_probe.dart`: Android profile entry point using
  production services. Reads `config.json` from the app-specific external
  `files/following_distance_benchmark/` folder. `{"mode":"memory"}` runs the
  staged memory test; `{"mode":"dataset"}` consumes `dataset/manifest.json`
  and its relative image files, and writes `predictions.jsonl`.
- `capture_following_distance_memory.py`: one-second `dumpsys` sampling and
  phase summaries. `--summarize-only` reuses preserved samples without touching
  the phone.
- `kitti_following_distance_benchmark.py`: small HTTP range downloads with ZIP
  CRC checks, calibration/annotation preparation, contact sheets, metric scoring,
  and scoring self-tests. It does not download full driving archives.
- `following_distance_benchmark_replay_test.dart`: checks all captured
  observations against production selection/grading, then checks the reference
  grades and the one confirmed violation using the actual production grader.

From `flutter_driving_app/`, with the evaluation Python dependencies installed:

```text
python -m pip install -r tool/following_distance_benchmark_requirements.txt
python tool/kitti_following_distance_benchmark.py prepare --drives 0056 0015 0032
python tool/kitti_following_distance_benchmark.py contact-sheets
python tool/kitti_following_distance_benchmark.py self-test
flutter build apk --profile --target-platform android-arm64 --target tool/following_distance_benchmark_probe.dart --no-pub
```

The preparation writes ignored data under `build/following_distance_benchmark/`.
Copy this report's `reference_review.json` there to reproduce the exact scored
intervals. For a new evaluation, independently review and freeze lead labels
before inference. Install the APK, open it once to create the app-specific
directory and enable camera permission, then copy the prepared `dataset/`
and selected `config.json` into that directory using ADB. The default package
ID is `com.example.flutter_driving_app`; installing this target replaces an
existing build with that ID. Preserve an existing installation when reproducing
on another phone.

For memory mode, configure the file first, then run:

```text
python tool/capture_following_distance_memory.py --serial DEVICE_SERIAL --seconds 150
```

For dataset mode, restart the app after configuring the file, wait for
`dataset_complete`, retrieve its `predictions.jsonl` into
`build/following_distance_benchmark/phone_predictions.jsonl`, and run:

```text
python tool/kitti_following_distance_benchmark.py score
flutter test tool/following_distance_benchmark_replay_test.dart --reporter expanded
```

The preparation manifest records image checksums and every production
following-distance Dart file/model checksum. They were checked against the
workspace again after inference. This report preserves the manifest, review,
all 99 predictions, the 65-row scored CSV, memory logs, summaries and run hashes.

Artifacts: [accuracy summary](accuracy_summary.json),
[scored frames](scored_frames.csv), [all phone predictions](phone_predictions.jsonl),
[dataset manifest](manifest.json), [dataset event log](dataset_events.jsonl),
[run metadata](run_metadata.json).

The source-analysis and artifact-replay results are recorded in
[verification.txt](verification.txt).
