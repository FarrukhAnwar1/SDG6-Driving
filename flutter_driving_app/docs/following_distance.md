# Live following-distance grading

This change covers the Live Dashboard, completed `TripSummary`, immediate
Driving Report, and transfer of those finalized results into the existing
upload queue. Database changes, backend endpoints, the Pocket Settings card,
saved-report parsing, Analytics, and Driving Family are separate tasks.
The shared driving-mode enum includes Pocket so the dashboard can be started
with that mode and correctly finalize its results.

## Modes and grades

| Mode | Speed | Braking / acceleration / turning | Focus | Following distance | Overall divisor |
| --- | --- | --- | --- | --- | --- |
| Regular (`normal` in Dart) | Yes | All three | Yes | Yes | 6 |
| Navigation | Yes | All three | No | Yes | 5 |
| Pocket | Yes | All three | No | No | 4 |

The dashboard presents the arithmetic mean of the three smoothness grades as
one Smoothness row. All three remain separate inputs to the overall grade,
summary, violations, and upload. Untracked categories contribute neither a
score nor a divisor entry; Pocket has explicit null focus/following scores and
neither violation type. Navigation has null focus and no focus violations.
Actual zero scores remain zero.

The dashboard and completed Driving Report hide categories excluded by the
driving mode entirely: Navigation omits Focus, and Pocket omits both Focus and
Following Distance. Neither screen shows a "Not tracked" placeholder for them.

## Detector and distance baseline

`FollowingDistanceCamera` runs the bundled COCO-pretrained YOLO11n detection
model on the rear camera through pinned `ultralytics_yolo` 0.6.16. Android uses
TFLite and iOS uses Core ML. Both inference and delivery are capped at 5 FPS.
No original images are requested, recorded, stored with the trip, or uploaded.
The small preview helps check that the mounted camera faces the road. The
existing permissions gate must already have granted camera permission; this
component checks permission without opening a dialog during a trip.

See [model provenance and checksums](../assets/models/README.md). The Android
model has a 320x320 input, 80 COCO labels, and embedded metadata. Car,
motorcycle, bus, and truck detections are eligible. Native inference and the
estimator both use a 0.30 confidence floor. Detections at 0.60 or higher can
start tracking immediately; lower-confidence candidates require three
overlapping observations spanning at least 300 ms. Pending confirmation has no
distance and cannot start a violation's grace period. Missing frames or a
different vehicle restart confirmation. A confirmed vehicle can continue at
the lower floor without flickering each time confidence crosses 0.60.

Boxes must be finite, complete/non-clipped, at least 0.02 of frame width, and
centered in the horizontal 0.35-0.65 corridor. There is no fixed vertical
cutoff: the road's position in the image changes with the phone mount. Adjacent
vehicles are excluded before checking confidence/clipping, so uncertain cars
in another lane do not generate a misleading unclear-road status. Select the
nearest eligible vehicle. The UI distinguishes confirmation, an uncertain
distance, and no *detected* lead vehicle; it cannot certify an empty road.

The estimate uses `distance = assumed vehicle width * normalized focal length
/ normalized box width`. Assumed widths are 1.8 m for cars, 0.8 m for
motorcycles, and 2.5 m for buses/trucks. Estimates outside 1-120 m are rejected.

The previous assumed 60-degree horizontal FOV has been removed. A small app
platform channel reads the same default rear camera used by the pinned
detector, without opening a second camera or changing its capture session:

- Android uses CameraX's default back-camera selector, Camera2 physical sensor
  dimensions, active/full pixel-array sizes, a single reported focal length,
  and the current zoom ratio. Multi-focal devices whose active focal length
  cannot be established from this metadata return unavailable rather than
  guessing. See [Android camera characteristics](https://developer.android.com/reference/android/hardware/camera2/CameraCharacteristics).
- iOS matches the detector's triple/dual-wide/dual/wide rear-device preference
  and reads the active format's horizontal FOV, pixel dimensions, and zoom
  *after* inference starts. See [Apple's format FOV documentation](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/videofieldofview).

Android retains the detector's default rear-camera binding at native 1x;
calling the plugin's zoom setter there can switch physical lenses. iOS sets
display zoom to 1x on its virtual device before reading metadata.
`RoadCameraGeometry` uses the
upright analysis frame's `imageWidth`/`imageHeight` to rotate the image plane
and account for center aspect-ratio cropping. In portrait the sensor's short
side is the horizontal axis. For example, a 6 x 4.5 mm sensor with a 4 mm lens
has normalized horizontal focal length 4/6 in landscape and 4/4.5 in portrait.
Applying the landscape value to portrait would shorten estimated distances
by 25%. No constant time offset or empirical multiplier is added.

No distance is graded while metadata is loading or unavailable, or when frame
dimensions are missing/invalid. A measured upright FOV can be explicitly
supplied with `FollowingDistanceCamera.horizontalFieldOfViewDegrees`; it is
never an automatic fallback. Preview size/cropping does not affect geometry.
Metadata is refreshed on resume, and a frame-size change starts a new target
identity so it cannot carry an unsafe streak across an orientation change.
Native channel changes require stopping and rerunning the app; hot reload
cannot register them.

Adjacent/off-axis vehicles are excluded by the corridor heuristic. Class and
box overlap associate a lead vehicle between frames; a changed target or lost
view resets its grace period. An implausible distance jump (ratio below 0.6 or
above 1.6 for overlapping boxes) is rejected. A three-frame median smooths
accepted distances to reduce isolated bounding-box width spikes, using only
the currently visible target. No distance is reused across a missing frame.

Camera metadata corrects the projection scale, but this remains an approximate
monocular baseline, not measured depth or lane detection. Vehicle sizes,
camera metadata errors, optical distortion/stabilization, mount angle, curves, hills,
occlusions, lighting, and nearby lanes affect estimates. No BDD100K fine-tuning,
KITTI/nuScenes validation, 70-75% accuracy, device RAM usage, or 20-50 ms
inference latency is claimed. Those require a separate model/dataset and
physical-device validation. Tune/calibrate against measured distances before
using these estimates as a validated driver-assessment metric.

## Grading and interruptions

- Begin at 100 with no recovery, consistent with the existing graders. A score
  of 100 means no confirmed penalty; it does not certify camera coverage.
- At speeds below 3 mph, do not grade following distance.
- Headway is `distanceMeters / (speedMph * 0.44704)`. Exactly 2 seconds is safe.
  An unsafe streak must continue **past 5 seconds** before it costs points.
- Charge only observed time after grace. Points per second are
  `1 + (2 - headwaySeconds) / 0.5`, so a 1-second gap costs 3 points/second after
  grace. Clamp the grade to 0-100. Grace-only candidates are not violations.
- Frames must be no more than 1 second old and use a trusted GPS fix no more
  than 2 seconds old. Frame/fix timestamps must be within 2 seconds of each
  other. Reject future timestamps beyond a 100 ms rounding allowance.
- More than 1 second between graded observations, missing/invalid GPS,
  unavailable or unreliable camera output, no lead vehicle, a safe gap, or a
  different lead vehicle ends the streak at the **last unsafe observation**.
  Never penalize an unobserved interval or merge across it. Ignore duplicate
  and out-of-order observations. A one-second dashboard watchdog also closes
  events when frames/fixes cease arriving entirely.
- The dashboard shows estimated headway or a waiting/unavailable/paused status.
  Interruptions preserve earned grades; they do not award or deduct points.
  The enabled category stays in its mode's average throughout interruptions.
- Leaving the foreground immediately pauses following-distance grading and
  the camera. Resuming clears the old GPS association and starts fresh grace.
  In Navigation the road camera cannot operate while another app is in front;
  those intervals are ungraded. Focus behavior remains specific to Regular.
- Stop Trip freezes the graders first, then stops the camera before opening
  the report. View disposal also releases the native model/camera and stream.
  Late callbacks cannot mutate a finalized summary. All summary violation
  lists are immutable snapshots.

Confirmed violations record start/end, starting GPS coordinates, starting
speed, minimum estimated headway/distance, and the duration actually penalized.
The report presents following distance in the same simple card style as the
other grades: an icon, category label, and percentage. It omits the estimate
note and violation breakdown. Recorded violation details remain in the trip
summary and upload payload.

## Upload handoff

New live reports pass `followingDistanceGrade` and
`followingDistanceViolations` from the same immutable summary that is displayed.
The existing queue serializes the score as `followingDistanceGrade` and each
event as `violationType: "Adequate Following Distance"` with UTC `startTime`,
`endTime`, `latitude`, and `longitude`. Pocket sends explicit null focus and
following scores and no corresponding events. Retries preserve the entire
request body and `clientTripId`; queue cleanup/account isolation are unchanged.

The backend/schema tasks must support this new field, enum value, and Pocket
mode before these new reports can be accepted. No backend compatibility
fallback strips the category, changes grades, or substitutes scores. A rejected
upload remains in the existing secure pending queue for retry.

## Verification

The detector is disabled on web and displays an unavailable-camera placeholder.
Its first unavailable callback is deferred until after the parent widget builds,
so the browser fallback can update dashboard state safely. Browser UI debugging
can use `flutter run -d edge --dart-define=ENVIRONMENT=dev_browser`; the existing
post-authentication flow bypasses native permission setup for that debug preset.
The existing live-trip GPS/sensor setup still requires a mobile device.

Check browser compilation with `flutter build web --debug`. Browser smoke tests
run with `flutter test --platform chrome test/following_distance/following_distance_web_test.dart`.
On Windows, `CHROME_EXECUTABLE` can point to Chromium-based Edge for these tests.
The installed Flutter 3.44.1 browser-test server returned 404 for its local
CanvasKit assets on Windows. The two browser smoke tests passed after the SDK's
unchanged CanvasKit files were temporarily served to the automated test tab.
This was a test-harness workaround; the normal web build succeeded directly.

Run `flutter analyze` and `flutter test`. Following-distance tests cover portrait
and landscape geometry, aspect-ratio cropping, unavailable metadata, stale
metadata after pause, confidence confirmation, box/target filtering, median
smoothing, thresholds, grace, severity, coordinates,
invalid readings, silent camera/GPS outages, background transitions, finalization,
all three mode averages, null versus zero, summary/report/upload transfer, and
unchanged retry bodies. Existing dashboard tests also check narrow screens and
larger text. `flutter build apk --debug --target-platform android-arm64` checks
native Android integration. iOS building and real road/camera accuracy,
permission revocation, heat, RAM, and latency need physical-device checks.
