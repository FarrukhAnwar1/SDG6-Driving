# Live following-distance grading

This frontend work covers the Live Dashboard, completed `TripSummary`, immediate
Driving Report, and finalized results in the existing upload queue. Database
changes, backend endpoints, the Pocket Settings card, saved-report parsing,
Analytics, and Driving Family remain separate tasks.

## Modes and presentation

| Mode | Speed | Braking / acceleration / turning | Focus | Following distance | Overall divisor |
| --- | --- | --- | --- | --- | --- |
| Regular (`normal` in Dart) | Yes | All three | Yes | Yes | 6 |
| Navigation | Yes | All three | No | Yes | 5 |
| Pocket | Yes | All three | No | No | 4 |

The dashboard shows one averaged Smoothness row, followed by Following Distance.
Following Distance shows its grade and progress bar without status or gap subtext.
All three smoothness grades still contribute separately to the overall grade,
summary and upload. Navigation entirely hides Focus; Pocket entirely hides Focus
and Following Distance on both the dashboard and report. Excluded categories
have null grades and no corresponding violations. Actual zero scores stay zero.
The report's following-distance card uses the same icon, label and percentage
presentation as the other grade cards, without an estimate or violation breakdown.

## Pretrained perception pipeline

One normal rear camera at 1x supplies both the preview and raw frames through
Flutter's `camera` plugin. Frames stay on the device; they are not recorded,
uploaded or retained in the trip. Audio is disabled. Android YUV420 plane
strides and sensor rotation, and iOS's already-oriented BGRA output, are handled
before either network sees the image. Model inputs preserve aspect ratio with
letterboxing; preview cropping never changes inference coordinates.

1. [YOLOP](https://github.com/hustvl/YOLOP) supplies pretrained BDD100K vehicle
   detections, drivable-surface segmentation and lane segmentation at 640x640.
   Its single vehicle class uses objectness multiplied by class score, followed
   by nonmaximum suppression. Padding is removed from boxes and mask lookups.
2. [UniDepthV2 Small](https://huggingface.co/lpiccinelli/unidepth-v2-vits14)
   supplies learned metric depth and camera intrinsics. Its fixed 532x392 input
   contains 208,544 pixels, within the upstream 200k–600k range, with dimensions
   divisible by 14. The export returns camera-forward Z in metres from the
   predicted 3D points. No assumed vehicle width, guessed focal length, or
   arbitrary distance multiplier is used.
3. Simple lead selection uses the current ego-lane detections and learned
   distances, without a separate tracking stage. A new lead needs confidence
   of at least 0.25 and can supply distance on its first sighting. A box matching
   the last observed lead can continue at confidence 0.10. Matching tolerates
   center movement of 75% of the larger box dimension (at least 6% of the image)
   and width/height ratios from 0.4 to 2.5, accommodating slow processing and box
   jitter. If the previous lead remains visible, a newly selected closer car
   gets a different identity and fresh grading grace. Identity can survive a
   miss for six seconds, but missing frames never supply a distance or continue
   a grading streak. There is no second-sighting confirmation requirement.

Lane boundaries and the drivable mask select an ego-lane candidate. Markings
are sampled at several rows near and below the tyres, including across dashed
line gaps, and projected back to tyre height using median slopes. A single
visible boundary still excludes traffic on its other side. Without a usable
pair, a centered fallback narrows for distant vehicles instead of using the
same horizontal window at every distance. The center and at least 60% of the
vehicle box must lie within the corridor; visible boundaries allow 1% of image
width for mask jitter. Cut-ins become eligible once most of the box is inside.
At least 12 of 200 lower-image road samples must be drivable, with additional
road evidence below or beside the vehicle's tyres, searched up to 12% of image
height below the box to tolerate occlusion and mask holes. Missing markings,
sharp curves, and off-center mounting can still make lane membership ambiguous.
Distance is the median of an interior body patch; clipped/tiny boxes,
nonfinite or out-of-range depth,
insufficient valid pixels, and excessive spatial depth spread produce an
uncertain result. UniDepth confidence is a relative uncertainty signal, not a
calibrated probability. A closer vehicle with uncertain depth prevents grading
a farther vehicle behind it. An abrupt distance jump breaks grading rather
than retaining an old distance. There is no multi-second temporal distance
average that would lag a vehicle moving away.

The app uses pinned `flutter_onnxruntime` 1.9.0 with bounded CPU thread pools
(four intra-op, one inter-op) and sequential network execution. Android and iOS
use the same ONNX assets. **The runtime requires iOS 16 or newer**; the Xcode
deployment targets reflect this. Android release rules preserve ONNX JNI names.
See [model sources, licenses, build instructions and validation](../assets/models/README.md).

These are pretrained components, not a validated following-distance product.
Monocular metric depth can still have scale bias, especially with unusual
mounts, poor light, small/distant vehicles, curves, or occlusion. Synthetic
regressions and export comparisons do not establish physical distance accuracy.
There is no claim of a fixed accuracy percentage, phone latency, or RAM target.
Recorded drives with measured distances/headways are needed to assess this
phone and mounting arrangement; BDD100K fine-tuning and KITTI/nuScenes validation
are not part of this frontend task.

## One-FPS timing and grading

The preview remains live. Analysis starts at most once per second. While a
frame is being processed, incoming frames are discarded: there is no inference
backlog. The camera plugin does not expose a hardware capture timestamp; the
app timestamps its raw-frame callback before preprocessing and keeps that time
through inference and grading. Results older than five seconds are unavailable.
The watchdog distinguishes an in-flight model job from camera silence. It
establishes one cutoff per outage, so repeated ticks cannot keep rejecting
fresh delayed results after recovery. These timing checks apply to grading;
the dashboard grade rows display labels and scores without monitoring subtext.
One FPS is a maximum target, not a guaranteed throughput: this CPH2655 took
about two seconds with a fixed test image and about 3.2 seconds with its live
rear-camera stream in the parked debug check. A longer allowance accepts those
results; it does not make inference faster.
One FPS responds more slowly to braking or cut-ins; it is a trip-grading setting,
not a collision-warning rate.

- Start at 100 with no recovery. A score of 100 means no confirmed penalty;
  it does not certify camera coverage.
- Grade only at or above **25 mph**. Headway is
  `distanceMeters / (speedMph * 0.44704)`. Exactly **1.5 seconds** is safe.
- A shorter gap must persist **past five seconds** before points are deducted.
  Grace is never charged. After grace, points per observed second are
  `1 + (1.5 - headwaySeconds) / 0.5`; a one-second gap costs two points/second.
  Scores are clamped to 0–100. Grace-only candidates are not violations.
- Use actual elapsed timestamps, not frame counts. At one FPS, up to 1.5 seconds
  between observations accommodates scheduling jitter. If a confirmed previous
  job took longer than one second, its measured processing time plus 500ms
  defines the next observation's deadline. Only a matching processing-start
  event can establish this allowance; a slow current result cannot excuse an
  earlier missing observation. A gap beyond that deadline, invalid distance/GPS,
  a safe gap, low speed,
  changed target or explicit interruption ends the streak at its last unsafe
  observation. Reacquisition gets fresh grace even when the track ID survives.
- Match each frame to a recent GPS fix at its observation time (within two
  seconds), while also requiring current GPS delivery to remain fresh. Keep
  eight seconds of fixes for inference latency. Future times beyond 100ms are
  rejected. A late result from before a GPS/camera fault cannot revive a streak.
- A one-second dashboard watchdog detects silent camera/GPS outages. Camera
  silence uses result delivery time and the five-second in-flight budget.
  Independently, raw camera callbacks continue while the model is busy: more
  than 1.5 seconds without a camera frame resets the tracker and grace and
  discards any pre-gap result. GPS faults and lifecycle interruptions do the
  same. Duplicate and out-of-order observations cannot charge.

The dashboard displays estimated headway or its existing waiting, confirming,
uncertain or unavailable status. Interruptions preserve earned grades. Speed
and smoothness continue through camera interruptions. Backgrounding closes the
camera and pauses following-distance grading; resume requires fresh GPS and a
new observation. Pocket never creates a road camera or depth session. Stopping
a trip freezes the graders, releases the camera before navigation, and waits
for in-flight inference before disposing native tensors and sessions. Late
callbacks cannot mutate the finalized result.

Violations retain start/end, starting coordinates and speed, minimum estimated
headway/distance, and actually penalized duration. Summary violation lists are
immutable snapshots.

## Upload handoff

The displayed immutable summary also supplies `followingDistanceGrade` and
`followingDistanceViolations` to the existing queue. Uploads use
`violationType: "Adequate Following Distance"` with UTC start/end and starting
coordinates. Pocket sends explicit null focus/following scores and neither
violation type; Navigation excludes only focus. Retries preserve the complete
body and `clientTripId`. No compatibility fallback strips this category or
substitutes a score. The separate API/schema work must accept these fields;
otherwise the existing queue retains the rejected upload for retry.

## Verification

Run `flutter analyze` and `flutter test`. Feature tests live under
`test/following_distance/` and cover preprocessing, output contracts, lane
selection, metric-depth quality, track association, one-FPS jitter and dropped
frames, GPS/inference synchronization, lifecycle cancellation, mode averages,
summary/report/upload transfer and retry preservation. Camera/model fakes keep
these tests deterministic; they do not establish model accuracy.

`flutter build apk --debug --target-platform android-arm64` checks Android
integration. `flutter build web --debug` checks browser compilation. Web and
other unsupported platforms display an unavailable camera placeholder without
loading native models; ordinary browser UI debugging remains available.
Use `flutter run -d edge --dart-define=ENVIRONMENT=dev_browser` for the existing
browser permission bypass. Live GPS/sensor trips still require a phone.
Browser smoke tests are in `following_distance_web_test.dart`; on Windows,
`CHROME_EXECUTABLE` may point to Edge. The installed Flutter 3.44.1 test server
has previously needed an SDK CanvasKit asset-serving workaround on Windows.

Windows cannot build iOS. Physical-phone checks must verify lens selection,
upright pixels, permissions/background resume, sustained cadence, heat/memory,
and measured headway before making accuracy or performance claims.

For a parked on-device integration check, `tool/road_monitoring_probe.dart`
runs the actual models, camera coordinator, timestamp/GPS join, watchdog and
grader with a fixed public road-image fixture and synthetic 90mph GPS. Its
default fixture path is the Android app's cache `road_probe_yuv420.bin` (640x480
I420, sensor oriented); override it with `ROAD_PROBE_INPUT`. Setting
`ROAD_PROBE_LIVE_CAMERA=true` checks the physical rear stream with the same
synthetic GPS. Both modes keep results local and create no trip or upload.
Restore the normal `lib/main.dart` entrypoint afterwards. These checks prove
runtime and timing behavior, not measured road-distance accuracy.
