// Decides forward/lateral vehicle-frame acceleration from the phone's
// raw accelerometer and gyroscope, regardless of how the phone happens to
// be mounted. Two independent, much simpler measurements replace what
// used to be a single continuously-fitted 2D rotation:
//
// 1. Gyro-aided gravity / tilt correction.
//    The raw accelerometer supplies an absolute long-term reference for the
//    phone's "up" direction, but it cannot distinguish gravity from vehicle
//    acceleration on its own. The gyroscope therefore propagates that up
//    direction at full sensor rate as the phone/car pitches and rolls, while
//    the accelerometer only nudges it back slowly when its reading is close to
//    the predicted gravity vector. This matters especially on vertical phone
//    mounts, where tiny pitch/roll wobble can otherwise project a large piece
//    of gravity into the measured forward/lateral axes.
//
// 2. Lateral (turning) G from the calibrated horizontal vehicle basis.
//    Before the forward axis is known, gyro yaw-rate × speed provides a
//    temporary estimate and, more importantly, a turn-rejection signal for
//    forward-axis calibration. Once forward is calibrated, lateral is simply
//    the perpendicular horizontal axis: lateralAxis = forwardAxis × upAxis.
//    Live lateral G then comes from the same gravity-corrected accelerometer
//    vector as forward G. This avoids multiplying small yaw vibration from a
//    flexible vertical phone mount by road speed and turning it into fake G.
//
// 3. Forward (braking/accelerating) G, from a calibrated forward axis.
//    Earlier revisions derived forward MAGNITUDE from
//    sqrt(horizontalMagnitude² - lateralAccel²) and applied GPS's speed
//    trend as an external +1/-1 SIGN. Both parts of that turned out to be
//    real problems, not just cosmetic ones:
//      - horizontalMagnitude and lateralAccel come from two different
//        sensors (accelerometer vs. gyro+GPS-speed) with independent
//        noise. Subtracting their squares under a sqrt is only
//        well-behaved when the two disagree by a lot; whenever they're
//        close together - which is exactly what steady, well-driven
//        cornering looks like, i.e. the single most common case a
//        smoothness grader needs to get right - a small sensor
//        disagreement gets blown up into a large phantom forward G (or
//        clamped straight to 0 if the disagreement points the other way).
//      - GPS speed trend updates at ~1 Hz, so applying it as an
//        externally-multiplied sign to an accelerometer-rate magnitude
//        means a brand-new event (e.g. a hard brake right after
//        accelerating) can report the PREVIOUS event's sign for up to a
//        full GPS interval - a real, not just cosmetic, direction error
//        for a system whose entire job is grading braking vs.
//        accelerating.
//    Both problems trace back to the same root cause: treating magnitude
//    and sign as two separately-derived pieces that get glued together
//    after the fact. The fix is to have one thing produce both magnitude
//    AND sign together, continuously, from a single measurement.
//
//    A phone rigidly mounted in a car doesn't rotate relative to the car
//    as the car turns - both turn together - so "which device-frame
//    direction is the car's forward" is a fixed property of the mount,
//    not something that needs to track the car's heading. That means it
//    can be calibrated once (from a clean, confidently-signed,
//    non-turning acceleration/braking event - see addAccelerometerSample
//    and _updateForwardAxis) and then just used directly:
//    forwardAccel = dot(linearAccel, forwardAxis). No gyro involved, no
//    subtraction of two independent noisy numbers, and the sign falls out
//    of the dot product itself at full accelerometer rate - there's no
//    separate, slower-updating sign variable to go stale.
//    GPS still matters here, just for a smaller job: labeling calibration
//    samples (this interval WAS accelerating vs. WAS braking). A GPS
//    speed trend only ever describes the interval BETWEEN two fixes, so
//    it's applied to the accelerometer vectors accumulated during that
//    same interval (timestamp-buffered in addAccelerometerSample, selected
//    by measurement time in addGpsSample once the interval's sign is known)
//    rather than to
//    whatever samples happen to arrive next - a live-updating GPS sign
//    applied forward in time would mislabel a brand-new event of the
//    opposite kind that starts right after a fix.
//
// Compared to the old fitted-rotation approach, this needs no
// continuously-refit horizontal basis, no Gram-Schmidt reference axis,
// and no least-squares accumulation. The lateral half is correct
// essentially immediately (bounded only by gyro bias, which starts at 0
// and self-corrects against GPS heading - see addGpsSample). The forward
// half needs a brief calibration window instead (typically the trip's
// first clear acceleration or braking event) before it reports anything
// other than 0 - see _forwardAxis and _updateForwardAxis.
//
// The gyro-derived turn estimate still needs current speed before forward
// calibration and for calibration gating. _estimatedSpeedMps dead-reckons
// between GPS fixes using forwardG and is resynced at every fix, so that
// temporary/gating estimate does not use a whole-second-stale speed.
//
// Known limitations:
//  - Gyroscope bias/drift is corrected against GPS heading changes (see
//    addGpsSample). That primarily affects the temporary pre-calibration
//    lateral estimate and the turn gate; once the forward axis is calibrated,
//    live lateral G is accelerometer-derived and no longer depends on yaw-rate
//    bias or speed.
//  - forwardG reads 0 until the forward axis has its first confident
//    calibration sample (see _updateForwardAxis) - in practice this is
//    whatever clean, non-turning acceleration or braking event happens
//    first, usually within the opening seconds of a trip (e.g. pulling
//    away from the first stop sign), but a trip that somehow never has
//    one would never grade forward G at all.
//  - The forward axis assumes the mount doesn't move mid-trip. If it
//    does (phone bumped, re-clipped at a different angle), forwardG will
//    read wrong until enough new confident, correctly-signed intervals
//    pull the slowly-adapting axis back into alignment - there's no fast
//    "detect the mount moved" check, only the same gradual EMA used for
//    ordinary refinement.
//  - The calibration gate compares each accelerometer sample's horizontal
//    magnitude against the MOST RECENT gyroscope-derived lateral estimate
//    (see addAccelerometerSample), even though the two streams aren't
//    timestamp-aligned. At normal sensor rates this is a minor effect; a
//    turn transition can occasionally pass/fail the gate on the wrong side.
//    The later interval-level coherence check makes an accidental sample much
//    less likely to influence the calibrated axis, so a timestamped gyro
//    history is not currently worth the extra complexity.
//  - Gravity/tilt uses a lightweight gyro+accelerometer complementary
//    estimate rather than a platform rotation-vector API. Gyro propagation
//    handles fast mount/car pitch and roll; the accelerometer supplies slow
//    drift correction. Very loose/flexible mounts can still inject real
//    translational and rotational vibration, so the final G outputs are also
//    low-pass filtered before grading/display.
//  - The device axis conventions and sign handling this relies on (see
//    the comment in addGyroscopeSample) are worth confirming on real
//    hardware across mount orientations before trusting the sign of
//    lateralG in production. A concrete way to check: drive with the
//    phone mounted normally and make a clear, deliberate right turn;
//    lateralG should read positive during it.
import 'dart:math' as math;
import 'package:sensors_plus/sensors_plus.dart';

class OrientationCalibrationService {
  OrientationCalibrationService({
    this._gravityAccelCorrectionTimeConstantSeconds =
        1.5, // accel slowly removes gyro tilt drift when the phone is not under strong linear acceleration
    this._gravityMotionGateReferenceMps2 =
        0.5, // above ~0.05g residual, trust gyro propagation increasingly more than accelerometer direction
    this._outputFilterTimeConstantSeconds =
        0.12, // suppress mount/road vibration while preserving real braking/turning events
    this._minMovingSpeedMps =
        1.34, // about 3 mph; below this, GPS speed trend is too noisy to trust for forward sign
    this._minHeadingSpeedMps =
        2.68, // about 6 mph; heading is too noisy below this to correct gyro bias against
    this._minForwardSignalMps2 =
        0.3, // ignore GPS speed-trend changes this small when deciding forward sign; likely just noise
    this._gyroBiasLearningRate =
        0.02, // how fast the gyro bias estimate adapts toward each GPS-confirmed correction
    this._maxTrustedHeadingAccuracyDegrees =
        15.0, // skip a gyro bias correction if reported heading accuracy is worse than this
    this._minCalibrationHorizontalMps2 =
        1.0, // ~0.1g; ignore weaker events as too noisy to calibrate the forward axis from
    this._maxCalibrationLateralFraction =
        0.35, // reject a calibration sample if lateral is more than this fraction of horizontal magnitude (i.e. too much turning mixed in)
    this._forwardAxisLearningRate =
        0.05, // how fast the forward axis adapts toward each qualifying calibration sample, after the first (snapped) one
    this._minCalibrationSampleCount =
        8, // minimum qualifying samples; paired with duration so behavior is not tied only to sensor rate
    this._minCalibrationDuration = const Duration(
      milliseconds: 150,
    ), // require the qualifying samples to span real time, not just arrive in a short high-rate burst
    this._minCalibrationCoherence =
        0.75, // reject mixed/oscillating intervals whose qualifying acceleration vectors do not agree on one direction
    this._minInitialCalibrationCoherence =
        0.85, // the first axis update snaps immediately, so require stronger directional agreement than later EMA refinements
  });

  static const double _gravityMetersPerSecondSquared = 9.80665;

  final double _gravityAccelCorrectionTimeConstantSeconds;
  final double _gravityMotionGateReferenceMps2;
  final double _outputFilterTimeConstantSeconds;
  final double _minMovingSpeedMps;
  final double _minHeadingSpeedMps;
  final double _minForwardSignalMps2;
  final double _gyroBiasLearningRate;
  final double _maxTrustedHeadingAccuracyDegrees;
  final double _minCalibrationHorizontalMps2;
  final double _maxCalibrationLateralFraction;
  final double _forwardAxisLearningRate;
  final int _minCalibrationSampleCount;
  final Duration _minCalibrationDuration;
  final double _minCalibrationCoherence;
  final double _minInitialCalibrationCoherence;

  // Estimated gravity-specific-force vector in DEVICE coordinates. At rest
  // an accelerometer reports the support force opposite physical gravity, so
  // this points UP and has approximately g magnitude. The gyroscope rotates
  // this vector immediately when the phone/car pitches or rolls; the raw
  // accelerometer only provides slow drift correction. Keeping fast tilt out
  // of the linear-acceleration residual is important for vertical mounts.
  double _gx = 0, _gy = _gravityMetersPerSecondSquared, _gz = 0;
  bool _hasGravityEstimate = false;
  DateTime? _lastGravityAccelCorrectionTimestamp;

  // Persistent gyroscope yaw-rate bias, in rad/s, in the SAME sign
  // convention as yLateral (positive = turning right) - see
  // addGyroscopeSample. Starts at 0 and is slowly corrected against GPS
  // heading changes in addGpsSample.
  double _yawBiasRadPerSec = 0.0;

  // Accumulates the (bias-UNcorrected) signed yaw rate, integrated over
  // time, between GPS fixes - i.e. "how much heading change the raw gyro
  // thinks happened" - so addGpsSample can compare it against the actual
  // GPS-reported heading change over that same interval to refine
  // _yawBiasRadPerSec.
  double _pendingYawIntegralRad = 0.0;
  DateTime? _lastGyroTimestamp;

  double? _lastGpsSpeedMps;
  double? _lastGpsHeadingDegrees;
  DateTime? _lastGpsTimestamp;

  // Qualifying (strong, non-turning) horizontal linear-accel samples are
  // buffered with their sensor timestamps. A GPS speed trend describes a
  // measurement interval, not a callback-arrival interval, so addGpsSample
  // selects only samples whose timestamps actually fall inside the GPS
  // interval it is labeling. Samples newer than a delayed GPS fix remain in
  // the buffer for the next interval instead of being mislabeled.
  final List<_CalibrationSample> _pendingCalibrationSamples = [];

  // Calibrated "vehicle forward" direction, in device coordinates
  // (unit vector, or null before the first confident calibration sample -
  // see _updateForwardAxis). Because the phone is rigidly mounted, this
  // direction is fixed relative to the device regardless of how the car
  // turns. Together with the fused up axis it also defines lateral.
  List<double>? _forwardAxis;

  // Dead-reckoned current speed (see addGpsSample and
  // _advanceEstimatedSpeed), used in place of the last raw GPS speed for
  // lateralAccel = speed * yawRate so a speed change between GPS fixes
  // doesn't get ignored - most noticeable when accelerating or braking
  // WHILE turning. Null until the first GPS fix.
  double? _estimatedSpeedMps;
  DateTime? _lastAccelerometerTimestamp;

  // Live filtered lateral acceleration. Before forward-axis calibration it
  // temporarily mirrors the gyro-derived estimate; after calibration it is
  // measured directly from the gravity-corrected accelerometer.
  double _lateralAccelMps2 = 0.0;

  // Separate gyro-derived lateral estimate used for the calibration turn gate
  // even after live lateral output has switched to accelerometer projection.
  double _gyroLateralAccelMps2 = 0.0;

  double _forwardG = 0.0;
  double _filteredYawRateRadPerSec = 0.0;
  bool _hasFilteredYawRate = false;
  DateTime? _lastForwardFilterTimestamp;
  DateTime? _lastLateralFilterTimestamp;

  // Forward G for the most recently processed accelerometer sample.
  // Positive = accelerating forward, negative = braking (matches the
  // sign convention smoothness grading already expects).
  double get forwardG => _forwardG;

  // Current filtered lateral G. After forward-axis calibration this is
  // accelerometer-derived; before calibration it temporarily uses gyro yaw.
  // Positive = turning right.
  double get lateralG => _lateralAccelMps2 / _gravityMetersPerSecondSquared;

  // Normalized "up" direction in device coordinates from the current
  // gravity estimate, or null if there isn't a usable one yet.
  List<double>? _currentUpAxis() {
    final gNorm = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    if (gNorm < 1e-6) return null; // no usable gravity reading yet
    return [_gx / gNorm, _gy / gNorm, _gz / gNorm];
  }

  // Feed one raw accelerometer sample (gravity included - do not use the
  // platform's pre-filtered "user accelerometer" stream, since the
  // gravity component is exactly what this needs). Updates the
  // tilt/gravity estimate and this sample's forward G.
  void addAccelerometerSample(AccelerometerEvent event) {
    final rawAccelMagnitude = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );
    if (!_hasGravityEstimate) {
      // The first reading establishes only DIRECTION; force the magnitude to
      // standard g so initial linear acceleration cannot permanently change
      // the estimated gravity magnitude.
      if (rawAccelMagnitude < 1e-6) return;
      _gx = (event.x / rawAccelMagnitude) *
          _gravityMetersPerSecondSquared;
      _gy = (event.y / rawAccelMagnitude) *
          _gravityMetersPerSecondSquared;
      _gz = (event.z / rawAccelMagnitude) *
          _gravityMetersPerSecondSquared;
      _hasGravityEstimate = true;
      _lastGravityAccelCorrectionTimestamp = event.timestamp;
    } else if (rawAccelMagnitude >= 1e-6) {
      // The gyro (see addGyroscopeSample) already follows FAST tilt changes.
      // The accelerometer is only the long-term absolute reference. Gate its
      // correction aggressively whenever the reading disagrees with predicted
      // gravity, because that disagreement is usually vehicle acceleration or
      // mount vibration rather than a reason to rotate the gravity estimate.
      final apparentMotion = math.sqrt(
        (event.x - _gx) * (event.x - _gx) +
            (event.y - _gy) * (event.y - _gy) +
            (event.z - _gz) * (event.z - _gz),
      );
      final ratio = apparentMotion / _gravityMotionGateReferenceMps2;
      final ratioSquared = ratio * ratio;
      final motionGate = 1.0 / (1.0 + ratioSquared * ratioSquared);

      final previousCorrectionTime = _lastGravityAccelCorrectionTimestamp;
      _lastGravityAccelCorrectionTimestamp = event.timestamp;
      if (previousCorrectionTime != null) {
        final dtSeconds = event.timestamp
                .difference(previousCorrectionTime)
                .inMicroseconds /
            1e6;
        if (dtSeconds > 0 && dtSeconds < 1.0) {
          final baseGain = 1.0 - math.exp(
            -dtSeconds / _gravityAccelCorrectionTimeConstantSeconds,
          );
          final gain = baseGain * motionGate;

          final currentAxis = _currentUpAxis();
          if (currentAxis != null) {
            final measuredUx = event.x / rawAccelMagnitude;
            final measuredUy = event.y / rawAccelMagnitude;
            final measuredUz = event.z / rawAccelMagnitude;
            var ux = currentAxis[0] + gain * (measuredUx - currentAxis[0]);
            var uy = currentAxis[1] + gain * (measuredUy - currentAxis[1]);
            var uz = currentAxis[2] + gain * (measuredUz - currentAxis[2]);
            final norm = math.sqrt(ux * ux + uy * uy + uz * uz);
            if (norm > 1e-6) {
              ux /= norm;
              uy /= norm;
              uz /= norm;
              _gx = ux * _gravityMetersPerSecondSquared;
              _gy = uy * _gravityMetersPerSecondSquared;
              _gz = uz * _gravityMetersPerSecondSquared;
            }
          }
        }
      }
    }

    final linX = event.x - _gx;
    final linY = event.y - _gy;
    final linZ = event.z - _gz;

    final axis = _currentUpAxis();
    if (axis == null) return; // practically unreachable; hold last known G
    final dx = axis[0], dy = axis[1], dz = axis[2];

    // Horizontal (perpendicular-to-gravity) VECTOR of linear acceleration -
    // not just its magnitude. This is what both the forward-axis
    // calibration below and the final projection need; it's still
    // basis-independent to compute (no horizontal reference axis is
    // needed to find it, only the up axis from gravity).
    final alongAxis = linX * dx + linY * dy + linZ * dz;
    final horizX = linX - alongAxis * dx;
    final horizY = linY - alongAxis * dy;
    final horizZ = linZ - alongAxis * dz;
    final horizontalMagSquared =
        horizX * horizX + horizY * horizY + horizZ * horizZ;

    // Accumulate this sample into the current GPS interval's forward-axis
    // calibration candidate, if it's clean enough to trust (strong
    // enough signal, not much turning mixed in). The SIGN for this
    // interval isn't decided here - it isn't known until the interval's
    // GPS fix arrives (see addGpsSample) - so only raw, un-signed
    // vectors get buffered; they're labeled against the correct interval
    // later, not against whatever sign happened to be current when each
    // sample arrived.
    final lateralMagSquared =
        _gyroLateralAccelMps2 * _gyroLateralAccelMps2;
    if (horizontalMagSquared >=
            _minCalibrationHorizontalMps2 * _minCalibrationHorizontalMps2 &&
        lateralMagSquared <=
            _maxCalibrationLateralFraction *
                _maxCalibrationLateralFraction *
                horizontalMagSquared) {
      final lastGpsTimestamp = _lastGpsTimestamp;
      // Before the first GPS fix there is no interval to label. Once a
      // baseline exists, retain the timestamp so delayed GPS callbacks can
      // still partition samples by measurement time correctly.
      if (lastGpsTimestamp != null &&
          event.timestamp.isAfter(lastGpsTimestamp)) {
        _pendingCalibrationSamples.add(
          _CalibrationSample(
            timestamp: event.timestamp,
            x: horizX,
            y: horizY,
            z: horizZ,
            magnitude: math.sqrt(horizontalMagSquared),
          ),
        );
      }
    }

    final forwardAxis = _forwardAxis;
    if (forwardAxis == null) {
      // No confident calibration sample yet (see _updateForwardAxis) -
      // report nothing rather than guessing, so a startup window never
      // shows a wrong-signed or fabricated forward G. This is normally
      // brief: the trip's first clean acceleration or braking event
      // calibrates it.
      _forwardG = 0.0;
      _advanceEstimatedSpeed(event.timestamp);
      return;
    }

    // Re-orthogonalize the calibrated axis against the CURRENT up-axis
    // estimate before using it, in case gravity/tilt has drifted a little
    // since the axis was last calibrated. This is a cheap, bounded
    // per-sample correction on an otherwise-fixed axis - nothing like the
    // old design's continuously-refit basis, since forwardAxis itself only
    // changes slowly and rarely (see _updateForwardAxis).
    final rawFx = forwardAxis[0];
    final rawFy = forwardAxis[1];
    final rawFz = forwardAxis[2];
    final forwardAlongUp = rawFx * dx + rawFy * dy + rawFz * dz;
    final fx = rawFx - forwardAlongUp * dx;
    final fy = rawFy - forwardAlongUp * dy;
    final fz = rawFz - forwardAlongUp * dz;
    final fNorm = math.sqrt(fx * fx + fy * fy + fz * fz);
    if (fNorm < 1e-6) return; // practically unreachable; hold last known G
    final nfx = fx / fNorm;
    final nfy = fy / fNorm;
    final nfz = fz / fNorm;

    // _forwardAxis is deliberately oriented so accelerometer projection is
    // positive during vehicle acceleration. With the accelerometer's proper-
    // acceleration sign, forward × up points toward the accelerometer-positive
    // lateral direction (positive for a vehicle right turn).
    var lateralX = nfy * dz - nfz * dy;
    var lateralY = nfz * dx - nfx * dz;
    var lateralZ = nfx * dy - nfy * dx;
    final lateralNorm = math.sqrt(
      lateralX * lateralX + lateralY * lateralY + lateralZ * lateralZ,
    );
    if (lateralNorm > 1e-6) {
      lateralX /= lateralNorm;
      lateralY /= lateralNorm;
      lateralZ /= lateralNorm;
      final rawLateralAccelMps2 =
          linX * lateralX + linY * lateralY + linZ * lateralZ;

      final previousLateralFilterTime = _lastLateralFilterTimestamp;
      _lastLateralFilterTimestamp = event.timestamp;
      if (previousLateralFilterTime == null) {
        _lateralAccelMps2 = rawLateralAccelMps2;
      } else {
        final lateralDtSeconds = event.timestamp
                .difference(previousLateralFilterTime)
                .inMicroseconds /
            1e6;
        if (lateralDtSeconds > 0 && lateralDtSeconds < 1.0) {
          final lateralAlpha = 1.0 - math.exp(
            -lateralDtSeconds / _outputFilterTimeConstantSeconds,
          );
          _lateralAccelMps2 +=
              lateralAlpha * (rawLateralAccelMps2 - _lateralAccelMps2);
        } else {
          _lateralAccelMps2 = rawLateralAccelMps2;
        }
      }
    }

    // Forward G, directly: magnitude AND sign both fall out of one
    // projection of one measurement, at full accelerometer rate - unlike
    // the old sqrt(horizontal² - lateral²) formula, this never subtracts
    // two independently-noisy numbers, and unlike applying GPS sign
    // externally, there's no separate, slower-updating sign to go stale.
    // Forward and lateral are now two direct projections of the same
    // gravity-corrected accelerometer vector onto an orthonormal horizontal
    // vehicle basis.
    final forwardAccelMps2 = linX * nfx + linY * nfy + linZ * nfz;
    final rawForwardG = forwardAccelMps2 / _gravityMetersPerSecondSquared;

    // A vertical clamp mount can physically ring/vibrate far more than a
    // phone lying flat. Real braking/acceleration is comparatively low
    // frequency, so a short time-constant low-pass removes mount buzz without
    // introducing GPS-scale latency.
    final previousFilterTime = _lastForwardFilterTimestamp;
    _lastForwardFilterTimestamp = event.timestamp;
    if (previousFilterTime == null) {
      _forwardG = rawForwardG;
    } else {
      final dtSeconds = event.timestamp
              .difference(previousFilterTime)
              .inMicroseconds /
          1e6;
      if (dtSeconds > 0 && dtSeconds < 1.0) {
        final alpha = 1.0 - math.exp(
          -dtSeconds / _outputFilterTimeConstantSeconds,
        );
        _forwardG += alpha * (rawForwardG - _forwardG);
      } else {
        _forwardG = rawForwardG;
      }
    }
    _advanceEstimatedSpeed(event.timestamp);
  }

  // Dead-reckons speed between GPS fixes using forwardG. This is used only
  // by the gyro-derived temporary/pre-calibration lateral estimate and the
  // calibration turn gate; post-calibration live lateral G is accelerometer-
  // derived and no longer depends on speed. The estimate is resynced at every
  // GPS fix so integration error cannot compound across intervals.
  void _advanceEstimatedSpeed(DateTime sampleTime) {
    final previousTimestamp = _lastAccelerometerTimestamp;
    _lastAccelerometerTimestamp = sampleTime;
    final speedEstimate = _estimatedSpeedMps;
    if (previousTimestamp == null || speedEstimate == null) return;

    final dtSeconds =
        sampleTime.difference(previousTimestamp).inMicroseconds / 1e6;
    // Guard against duplicate/out-of-order samples and long gaps, same
    // idea as the gyro integral's own guard.
    if (dtSeconds <= 0 || dtSeconds >= 1.0) return;

    final forwardAccelForSpeedMps2 =
        _forwardG * _gravityMetersPerSecondSquared;
    _estimatedSpeedMps = math.max(
      0.0,
      speedEstimate + forwardAccelForSpeedMps2 * dtSeconds,
    );
  }

  // Snaps (on the first confident calibration) or slowly nudges
  // (thereafter) the calibrated forward axis toward an already-averaged,
  // already-signed candidate direction for a GPS interval that just
  // completed - see addGpsSample for how that candidate is assembled
  // (averaged from buffered accelerometer samples) and correctly
  // time-aligned with its sign (the interval's own GPS-derived speed
  // trend, not whatever sign was current when each sample arrived).
  void _updateForwardAxis(
    double candidateX,
    double candidateY,
    double candidateZ,
  ) {
    final existing = _forwardAxis;
    if (existing == null) {
      // First confident calibration - snap directly, the same idea as
      // the gravity estimate snapping to its first real reading, so the
      // trip doesn't spend its opening events slowly drifting toward a
      // usable axis from an arbitrary placeholder.
      _forwardAxis = [candidateX, candidateY, candidateZ];
      return;
    }

    // Already calibrated: nudge slowly toward this interval's candidate
    // rather than re-fitting from scratch, so one noisy or borderline
    // interval can't yank the forward axis around - deliberately the
    // opposite failure mode from the old design's continuously-refit
    // basis rotating underneath accumulated state.
    var fx =
        existing[0] + _forwardAxisLearningRate * (candidateX - existing[0]);
    var fy =
        existing[1] + _forwardAxisLearningRate * (candidateY - existing[1]);
    var fz =
        existing[2] + _forwardAxisLearningRate * (candidateZ - existing[2]);
    final norm = math.sqrt(fx * fx + fy * fy + fz * fz);
    if (norm > 1e-6) {
      _forwardAxis = [fx / norm, fy / norm, fz / norm];
    }
  }

  // Feed one raw gyroscope sample. It has three jobs: propagate the fused
  // gravity/up direction through fast pitch/roll, maintain a filtered yaw-rate
  // turn estimate for calibration gating, and provide temporary lateral G
  // before the forward/lateral accelerometer basis has calibrated.
  void addGyroscopeSample(GyroscopeEvent event) {
    if (!_hasGravityEstimate) return;

    final now = event.timestamp;
    final previousTimestamp = _lastGyroTimestamp;
    _lastGyroTimestamp = now;
    double? gyroDtSeconds;
    if (previousTimestamp != null) {
      final dtSeconds = now.difference(previousTimestamp).inMicroseconds / 1e6;
      if (dtSeconds > 0 && dtSeconds < 1.0) {
        gyroDtSeconds = dtSeconds;

        // A fixed world-up vector expressed in rotating DEVICE coordinates
        // follows du/dt = u × omega. This lets the gravity estimate follow
        // rapid pitch/roll immediately instead of waiting for an accel LPF.
        final axisBefore = _currentUpAxis();
        if (axisBefore != null) {
          final ux = axisBefore[0];
          final uy = axisBefore[1];
          final uz = axisBefore[2];
          var nextUx =
              ux + (uy * event.z - uz * event.y) * dtSeconds;
          var nextUy =
              uy + (uz * event.x - ux * event.z) * dtSeconds;
          var nextUz =
              uz + (ux * event.y - uy * event.x) * dtSeconds;
          final norm =
              math.sqrt(nextUx * nextUx + nextUy * nextUy + nextUz * nextUz);
          if (norm > 1e-6) {
            nextUx /= norm;
            nextUy /= norm;
            nextUz /= norm;
            _gx = nextUx * _gravityMetersPerSecondSquared;
            _gy = nextUy * _gravityMetersPerSecondSquared;
            _gz = nextUz * _gravityMetersPerSecondSquared;
          }
        }
      }
    }

    final axis = _currentUpAxis();
    if (axis == null) return;
    final dx = axis[0], dy = axis[1], dz = axis[2];

    // Project the raw angular velocity onto the SAME up-pointing axis
    // used for gravity removal - this is the car's yaw rate, in the
    // gyroscope's own (standard right-hand-rule) sign convention.
    final rawUpAxisRateRadPerSec = event.x * dx + event.y * dy + event.z * dz;

    // Flip sign to match yLateral's convention (positive = turning
    // right): standard GPS heading increases CLOCKWISE as seen from
    // above, which is a NEGATIVE rotation about the up axis by the
    // right-hand rule the gyroscope itself follows (unlike the
    // accelerometer, a gyroscope reports true angular velocity with no
    // extra sign quirk - this matches Android's own documented
    // convention: an observer positioned on the positive axis looking
    // back at the device sees a positive reading as counter-clockwise,
    // which for the "up" axis means a bird's-eye view from above, the
    // same viewpoint compass heading is defined from). So a right turn
    // reads as a NEGATIVE raw projection here, and needs negating to
    // read positive, matching yLateral.
    final signedYawRateRaw = -rawUpAxisRateRadPerSec;

    // Use the sensor-provided timestamp for both gravity propagation and
    // yaw integration; this avoids callback scheduling jitter contaminating
    // the complementary filter or the GPS heading-bias comparison.
    if (gyroDtSeconds != null) {
      _pendingYawIntegralRad += signedYawRateRaw * gyroDtSeconds;
    }

    final signedYawRateRadPerSec = signedYawRateRaw - _yawBiasRadPerSec;
    if (!_hasFilteredYawRate || gyroDtSeconds == null) {
      _filteredYawRateRadPerSec = signedYawRateRadPerSec;
      _hasFilteredYawRate = true;
    } else {
      final alpha = 1.0 - math.exp(
        -gyroDtSeconds / _outputFilterTimeConstantSeconds,
      );
      _filteredYawRateRadPerSec +=
          alpha * (signedYawRateRadPerSec - _filteredYawRateRadPerSec);
    }

    final currentSpeedMps = _estimatedSpeedMps ?? 0.0;
    _gyroLateralAccelMps2 = currentSpeedMps * _filteredYawRateRadPerSec;

    // Before the forward axis exists, this is the only mount-independent
    // lateral estimate available. Once calibrated, addAccelerometerSample
    // owns live lateral output so mount yaw wobble is no longer speed-amplified.
    if (_forwardAxis == null) {
      _lateralAccelMps2 = _gyroLateralAccelMps2;
    }
  }

  // Feed one GPS fix. Unlike the old design, this is no longer the
  // primary source of lateral G - it's used only for (a) labeling the
  // forward-axis calibration candidate accumulated since the last fix
  // (see addAccelerometerSample), (b) resyncing the dead-reckoned speed
  // estimate (see _advanceEstimatedSpeed), and (c) slowly correcting
  // gyroscope yaw-rate bias against GPS heading. Speed should be the same
  // resolved speed used for display/grading (in m/s), not clamped to
  // zero for low-speed display purposes.
  void addGpsSample({
    required double speedMps,
    required double? headingDegrees,
    required DateTime timestamp,
    double? headingAccuracyDegrees,
  }) {
    final previousSpeed = _lastGpsSpeedMps;
    final previousHeading = _lastGpsHeadingDegrees;
    final previousTimestamp = _lastGpsTimestamp;

    // First accepted fix establishes the measurement-time baseline. There is
    // no previous GPS interval to calibrate or bias-correct yet.
    if (previousSpeed == null || previousTimestamp == null) {
      _lastGpsSpeedMps = speedMps;
      _lastGpsHeadingDegrees = headingDegrees;
      _lastGpsTimestamp = timestamp;
      _estimatedSpeedMps = speedMps;
      _pendingYawIntegralRad = 0.0;
      _pendingCalibrationSamples.removeWhere(
        (sample) => !sample.timestamp.isAfter(timestamp),
      );
      return;
    }

    final dtSeconds =
        timestamp.difference(previousTimestamp).inMilliseconds / 1000.0;

    // Truly ignore duplicate/out-of-order fixes. The older implementation
    // detected them only after overwriting _lastGps*, which silently rolled the
    // interval baseline backward and could corrupt the next derivative.
    if (dtSeconds <= 0.1) return;

    // A long gap cannot produce a trustworthy derivative. Treat this fix as a
    // fresh baseline, resync speed, and discard stale interval evidence rather
    // than trying to bridge the gap.
    if (dtSeconds > 5.0) {
      _lastGpsSpeedMps = speedMps;
      _lastGpsHeadingDegrees = headingDegrees;
      _lastGpsTimestamp = timestamp;
      _estimatedSpeedMps = speedMps;
      _pendingYawIntegralRad = 0.0;
      _pendingCalibrationSamples.removeWhere(
        (sample) => !sample.timestamp.isAfter(timestamp),
      );
      return;
    }

    final yawIntegralSinceLastFix = _pendingYawIntegralRad;
    _pendingYawIntegralRad = 0.0;

    // Select calibration samples by SENSOR timestamp, not by callback order.
    // GPS delivery can be delayed; an accelerometer sample that arrives before
    // this callback may actually belong to the NEXT GPS interval.
    final intervalCalibrationSamples = <_CalibrationSample>[];
    for (final sample in _pendingCalibrationSamples) {
      if (sample.timestamp.isAfter(previousTimestamp) &&
          !sample.timestamp.isAfter(timestamp)) {
        intervalCalibrationSamples.add(sample);
      }
    }
    // Everything at/before this GPS measurement time has now either been
    // consumed or deliberately rejected with this interval. Keep only newer
    // samples for the next fix.
    _pendingCalibrationSamples.removeWhere(
      (sample) => !sample.timestamp.isAfter(timestamp),
    );

    _lastGpsSpeedMps = speedMps;
    _lastGpsHeadingDegrees = headingDegrees;
    _lastGpsTimestamp = timestamp;
    // Resync the dead-reckoned speed estimate to GPS's own reading every
    // accepted fix so integration error never compounds beyond one interval.
    _estimatedSpeedMps = speedMps;

    final averageSpeed = (previousSpeed + speedMps) / 2;

    // --- Forward-axis calibration ---
    // Below minMovingSpeedMps, or when the change is too small, GPS
    // speed-trend noise dominates any real signal - skip calibrating
    // this interval rather than risk a mislabeled sample.
    if (averageSpeed >= _minMovingSpeedMps) {
      final yForward = (speedMps - previousSpeed) / dtSeconds;
      if (yForward.abs() >= _minForwardSignalMps2 &&
          intervalCalibrationSamples.length >= _minCalibrationSampleCount) {
        // This sign describes exactly [previousTimestamp, timestamp], and the
        // samples below are selected by their own timestamps from that same
        // measurement interval. This remains correct even if the GPS callback
        // itself arrives late.
        var sumX = 0.0;
        var sumY = 0.0;
        var sumZ = 0.0;
        var magnitudeSum = 0.0;
        DateTime? firstSampleTime;
        DateTime? lastSampleTime;
        for (final sample in intervalCalibrationSamples) {
          sumX += sample.x;
          sumY += sample.y;
          sumZ += sample.z;
          magnitudeSum += sample.magnitude;
          if (firstSampleTime == null ||
              sample.timestamp.isBefore(firstSampleTime)) {
            firstSampleTime = sample.timestamp;
          }
          if (lastSampleTime == null ||
              sample.timestamp.isAfter(lastSampleTime)) {
            lastSampleTime = sample.timestamp;
          }
        }

        final qualifyingSpan = lastSampleTime!.difference(firstSampleTime!);
        final vectorSumMagnitude = math.sqrt(
          sumX * sumX + sumY * sumY + sumZ * sumZ,
        );
        final coherence = magnitudeSum > 1e-9
            ? vectorSumMagnitude / magnitudeSum
            : 0.0;
        final requiredCoherence = _forwardAxis == null
            ? _minInitialCalibrationCoherence
            : _minCalibrationCoherence;

        // Count alone depends on sensor rate, so also require real elapsed
        // time. Coherence rejects mixed accelerate/brake or oscillating
        // intervals even when their net GPS speed change happens to be large.
        if (qualifyingSpan.compareTo(_minCalibrationDuration) >= 0 &&
            coherence >= requiredCoherence) {
          final sampleCount = intervalCalibrationSamples.length;
          final avgX = sumX / sampleCount;
          final avgY = sumY / sampleCount;
          final avgZ = sumZ / sampleCount;
          final avgMagSquared = avgX * avgX + avgY * avgY + avgZ * avgZ;
          if (avgMagSquared >=
              _minCalibrationHorizontalMps2 *
                  _minCalibrationHorizontalMps2) {
            final avgMag = math.sqrt(avgMagSquared);
            // Orient by this interval's sign: during braking the raw
            // horizontal vector points backward relative to the car, so
            // flipping by sign gives a consistently-oriented vehicle-forward
            // estimate whether this interval accelerated or braked.
            final sign = yForward.sign;
            _updateForwardAxis(
              (avgX / avgMag) * sign,
              (avgY / avgMag) * sign,
              (avgZ / avgMag) * sign,
            );
          }
        }
      }
    }

    // --- Gyro bias correction ---
    // Only trust this when heading itself would have been trustworthy
    // (same speed floor the old design used for exactly this reason),
    // and - when the caller supplies it - when reported heading accuracy
    // isn't obviously bad.
    final headingAccuracyOk =
        headingAccuracyDegrees == null ||
        (headingAccuracyDegrees > 0 &&
            headingAccuracyDegrees <= _maxTrustedHeadingAccuracyDegrees);
    if (headingDegrees != null &&
        previousHeading != null &&
        averageSpeed >= _minHeadingSpeedMps &&
        headingAccuracyOk) {
      var headingDeltaDegrees = headingDegrees - previousHeading;
      // Normalize to [-180, 180] so crossing the 0/360 boundary doesn't
      // look like a near-instant U-turn.
      headingDeltaDegrees =
          ((headingDeltaDegrees + 180) % 360 + 360) % 360 - 180;
      final actualSignedHeadingDeltaRad = headingDeltaDegrees * math.pi / 180;

      // How much the raw (uncorrected) gyro over- or under-reported
      // turning during this interval, spread over its duration. A long
      // straight, steady-speed stretch is actually the ideal condition
      // for this - true heading change is ~0, so any nonzero average
      // reading directly is the bias.
      final observedBias =
          (yawIntegralSinceLastFix - actualSignedHeadingDeltaRad) / dtSeconds;
      _yawBiasRadPerSec +=
          _gyroBiasLearningRate * (observedBias - _yawBiasRadPerSec);
    }
  }
}

class _CalibrationSample {
  const _CalibrationSample({
    required this.timestamp,
    required this.x,
    required this.y,
    required this.z,
    required this.magnitude,
  });

  final DateTime timestamp;
  final double x, y, z;
  final double magnitude;
}
