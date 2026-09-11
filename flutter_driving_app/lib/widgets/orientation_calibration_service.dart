// Decides forward/lateral vehicle-frame acceleration from the phone's
// raw accelerometer and gyroscope, regardless of how the phone happens to
// be mounted.
//
// 1. Gyro-aided gravity / tilt direction.
//    The raw accelerometer supplies an absolute long-term reference for the
//    phone's "up" direction, while the gyroscope propagates that direction at
//    full sensor rate as the phone/car pitches and rolls. This up
//    estimate is used only to define the horizontal vehicle plane as live
//    vehicle acceleration comes from sensors_plus UserAccelerometerEvent,
//    whose platform sensor has gravity removed already. That avoids turning a
//    small gravity-estimation error into fake forward/lateral G, which proves
//    especially important when the phone is physically landscape.
//
// 2. Lateral (turning) G comes from the calibrated horizontal vehicle basis.
//    Before the forward axis is known, gyro yaw-rate × speed provides a
//    temporary estimate and, more importantly, a turn-rejection signal for
//    forward-axis calibration. Once forward is calibrated, lateral is simply
//    the perpendicular horizontal axis: lateralAxis = forwardAxis × upAxis.
//    Live lateral G is projected from the platform gravity-removed linear
//    acceleration vector. This avoids both speed-amplified mount yaw wobble
//    and residual-gravity leakage from our own tilt estimate.
//
// 3. Forward (braking/accelerating) G comes from a calibrated forward axis.
//    A phone rigidly mounted in a car doesn't rotate relative to the car
//    as the car turns since both turn together so "which device-frame
//    direction is the car's forward" is a fixed property of the mount,
//    not something that needs to track the car's heading. That means it
//    can be calibrated once (from a clean, confidently-signed,
//    non-turning acceleration/braking event: see addUserAccelerometerSample
//    and _updateForwardAxis) and then just used directly:
//    forwardAccel = dot(linearAccel, forwardAxis).
//
// The lateral g-force half is correct
// essentially immediately (bounded only by gyro bias, which starts at 0
// and self-corrects against GPS heading: see addGpsSample). The forward
// half needs two confident, directionally-consistent calibration intervals
// before it reports anything other than 0: see _forwardAxis and
// _updateForwardAxis.
//
// Before forward calibration, gyro yaw-rate × the held/dead-reckoned speed is
// used only for the temporary live lateral display. Forward-axis CALIBRATION
// does not trust that potentially stale live speed: qualifying accelerometer
// samples store their contemporaneous gyro yaw rate, and addGpsSample applies
// the turn gate after the interval closes using the higher of the interval's
// two actual GPS endpoint speeds.
//
//
// Timestamp requirement:
//  - UserAccelerometerEvent/GyroscopeEvent timestamps and the GPS timestamp
//    passed to addGpsSample MUST represent the same DateTime timeline. Interval
//    partitioning intentionally uses measurement timestamps rather than callback
//    arrival order. If a different sensor/location provider is substituted,
//    normalize its timestamps before feeding this service.
//
// Known limitations:
//  - Gyroscope bias/drift is corrected against GPS heading changes (see
//    addGpsSample). Raw yaw-rate samples are timestamp-buffered and integrated
//    over the exact GPS measurement interval. Any interval with a >250 ms gyro
//    gap (including missing coverage near either GPS boundary) is skipped
//    rather than teaching a false bias. Once the forward axis is calibrated,
//    live lateral G is accelerometer-derived and no longer depends on yaw-rate
//    bias or speed.
//  - forwardG reads 0 until two directionally-consistent calibration intervals
//    establish the initial axis. Candidate admission is intentionally permissive
//    enough for ordinary deliberate accel/brake events, while the second
//    independent confirmation protects against one noisy GPS polarity label.
//  - Signed forward-axis calibration/refinement is disabled below [minForwardCalibrationSpeedMps].
//    GPS speed has no forward/reverse direction, so backing out of a driveway
//    or parking space must not be allowed to teach the service that vehicle
//    rear is +forward. After calibration has completed at normal road speed,
//    live forward/lateral G continues to work at any speed, including reverse.
//  - Mid-trip remounts are transported instead of invalidating calibration.
//    Large pitch/roll changes rotate the stored basis by the minimal rotation
//    mapping old UP to new UP. Large yaw-only phone rotations are corrected at
//    the next trustworthy GPS interval from (gyro yaw - vehicle heading change).
//    Later GPS-labelled forward candidates continue refining/correcting it.
//  - Calibration samples store the MOST RECENT filtered gyro yaw rate, so the
//    accelerometer and gyro streams still are not perfectly timestamp-aligned.
//    The speed-dependent turn gate itself is deferred until the GPS interval
//    closes and uses the higher endpoint GPS speed, eliminating the old stale-
//    speed underestimation. A very fast turn transition can still pair one
//    accelerometer sample with a slightly early/late yaw rate; interval
//    coherence and the two-confirmation polarity logic limit its influence.
//  - Gravity/tilt uses a lightweight gyro+accelerometer complementary
//    estimate rather than a platform rotation-vector API. Its job is
//    to define the horizontal plane and lateral-axis handedness.
//    Live acceleration uses the platform's
//    gravity-removed UserAccelerometerEvent. Very loose/flexible mounts can
//    still inject real translational vibration, so the final G outputs remain
//    low-pass filtered before grading/display.
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
    this._minForwardCalibrationSpeedMps =
        5.36448, // 12 mph. below this, do not use GPS speed trend to orient/refine the forward axis because normal reversing/parking speeds are direction-ambiguous
    this._minHeadingSpeedMps =
        2.68224, // exactly 6 mph. heading is too noisy below this to correct gyro bias against
    this._minForwardSignalMps2 =
        0.3, // ignore GPS speed-trend changes this small when deciding forward sign. likely just noise
    this._gyroBiasLearningRate =
        0.02, // how fast the gyro bias estimate adapts toward each GPS-confirmed correction
    this._maxTrustedHeadingAccuracyDegrees =
        15.0, // skip a gyro bias correction if reported heading accuracy is worse than this
    this._minCalibrationHorizontalMps2 =
        0.7, // ~0.07g. admit ordinary deliberate accel/brake events; coherence + two-confirmation polarity protection still reject weak/random motion
    this._maxCalibrationLateralFraction =
        0.35, // reject a calibration sample if lateral is more than this fraction of horizontal magnitude (i.e. too much turning mixed in)
    this._forwardAxisLearningRate =
        0.05, // how fast the forward axis adapts toward each qualifying calibration sample, after the first (snapped) one
    this._minCalibrationSampleCount =
        8, // minimum qualifying samples. paired with duration so behavior is not tied only to sensor rate
    this._minCalibrationDuration = const Duration(
      milliseconds: 150,
    ), // require the qualifying samples to span real time, not just arrive in a short high-rate burst
    this._minCalibrationCoherence =
        0.75, // reject mixed/oscillating intervals whose qualifying acceleration vectors do not agree on one direction
    this._minInitialCalibrationCoherence =
        0.80, // still stricter than later refinement, but attainable during normal road acceleration rather than only unusually clean/hard events
    this._minGpsToLinearAccelCalibrationRatio =
        0.20, // GPS derivatives lag phone acceleration; two independent consistent intervals protect polarity better than rejecting most normal events
    this._forwardAxisAgreementCosine =
        0.75, // candidates must be within ~41 degrees to count as agreeing on the same axis direction
    this._initialForwardAxisConfirmationsRequired =
        2, // never let one GPS interval decide the trip's +forward polarity
    this._basisTiltTransportThresholdCosine =
        0.8660254037844386, // cos(30°): larger UP-frame changes are treated as phone remounts rather than normal vehicle pitch/roll
    this._basisYawTransportThresholdRadians =
        0.5235987755982988, // 30°: large gyro-vs-GPS yaw disagreement is treated as phone-relative yaw remount
  });

  static const double _gravityMetersPerSecondSquared = 9.80665;

  // Defensive caps. A valid GPS derivative interval is at most 5 seconds, so
  // these retain far more history than calibration/bias correction can use
  // while preventing unbounded growth during extended GPS loss.
  static const int _maxPendingCalibrationSamples = 2048;
  static const int _maxPendingGyroSamples = 4096;

  // Bias correction requires effectively continuous gyro coverage. At game
  // sensor rate normal sample gaps are far smaller than this; a larger gap
  // means we skip that GPS interval instead of interpreting missed rotation as
  // gyroscope bias.
  static const Duration _maxGyroGapForBias = Duration(milliseconds: 250);

  final double _gravityAccelCorrectionTimeConstantSeconds;
  final double _gravityMotionGateReferenceMps2;
  final double _outputFilterTimeConstantSeconds;
  final double _minForwardCalibrationSpeedMps;
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
  final double _minGpsToLinearAccelCalibrationRatio;
  final double _forwardAxisAgreementCosine;
  final int _initialForwardAxisConfirmationsRequired;
  final double _basisTiltTransportThresholdCosine;
  final double _basisYawTransportThresholdRadians;

  // Estimated gravity-specific-force vector in DEVICE coordinates. At rest
  // an accelerometer reports the support force opposite physical gravity, so
  // this points UP and has approximately g magnitude. The gyroscope rotates
  // this vector immediately when the phone/car pitches or rolls while the raw
  // accelerometer only provides slow drift correction. Keeping fast tilt out
  // of the linear-acceleration residual is important for vertical mounts.
  double _gx = 0, _gy = _gravityMetersPerSecondSquared, _gz = 0;
  bool _hasGravityEstimate = false;
  DateTime? _lastGravityAccelCorrectionTimestamp;

  // Persistent gyroscope yaw-rate bias, in rad/s, in the SAME sign
  // convention as lateralG (positive = turning right): see
  // addGyroscopeSample. Starts at 0 and is slowly corrected against GPS
  // heading changes in addGpsSample.
  double _yawBiasRadPerSec = 0.0;

  // Raw signed yaw-rate samples are buffered with SENSOR timestamps.
  // addGpsSample integrates only samples belonging to the GPS measurement
  // interval being compared, so callback latency cannot shift the gyro window
  // relative to the GPS heading window.
  final List<_GyroSample> _pendingGyroSamples = [];
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
  // (unit vector, or null before the first confident calibration sample:
  // see _updateForwardAxis). Because the phone is rigidly mounted, this
  // direction is fixed relative to the device while the mounting is unchanged.
  // Physical remounts transport this basis using UP-frame change and relative
  // gyro-vs-GPS yaw; vehicle turns by themselves do not change it.
  List<double>? _forwardAxis;

  // UP direction in device coordinates corresponding to the currently stored
  // vehicle basis. Large changes let us transport an already-calibrated basis
  // into the phone's new coordinate frame instead of discarding calibration.
  List<double>? _basisUpAxis;

  // The vehicle-forward LINE can be learned from accelerometer direction, but
  // its + / - polarity comes from GPS speed trend. One noisy/lagged GPS interval
  // must not be allowed to mirror the whole vehicle basis, because reversing
  // forward also reverses lateral = forward x up.
  List<double>? _pendingInitialForwardAxis;
  int _pendingInitialForwardAxisConfirmations = 0;

  // If a clean GPS-labelled candidate differs from the active device-frame
  // forward axis by more than ~41 degrees, the phone was probably remounted
  // (including yaw-only remounts that happened while GPS heading was unusable).
  // Require a second mutually-consistent candidate before snapping to that new
  // mounting so one bad GPS derivative cannot rotate/swap the whole basis.
  List<double>? _pendingLargeRemountForwardAxis;
  int _pendingLargeRemountForwardAxisConfirmations = 0;

  // Dead-reckoned current speed (see addGpsSample and
  // _advanceEstimatedSpeed), used in place of the last raw GPS speed for
  // lateralAccel = speed * yawRate so a speed change between GPS fixes
  // doesn't get ignored. This is most noticeable when accelerating or braking
  // WHILE turning. Null until the first GPS fix.
  double? _estimatedSpeedMps;
  DateTime? _lastLinearAccelerationTimestamp;

  // Live filtered lateral acceleration. Before forward-axis calibration it
  // temporarily mirrors the gyro-derived estimate. After calibration it is
  // measured directly from the gravity-corrected accelerometer.
  double _lateralAccelMps2 = 0.0;

  // Gyro-derived temporary lateral estimate used only before the calibrated
  // accelerometer basis is available. Calibration itself stores yaw rate with
  // each sample and applies the speed-dependent turn gate at GPS interval close.
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

  // False means forwardG == 0 is a calibration placeholder, not necessarily a
  // physical zero. Callers that display or score forward acceleration can use
  // this to distinguish startup calibration from steady-speed driving.
  bool get isForwardCalibrated => _forwardAxis != null;

  // Useful for UI/debugging. 0/2 or 1/2 explains why forwardG is still
  // unavailable instead of presenting an unexplained dash.
  int get forwardCalibrationConfirmations =>
      _forwardAxis != null ? _initialForwardAxisConfirmationsRequired
                           : _pendingInitialForwardAxisConfirmations;
  int get forwardCalibrationConfirmationsRequired =>
      _initialForwardAxisConfirmationsRequired;

  // Current filtered lateral G. After forward-axis calibration this is
  // accelerometer-derived. Before calibration it temporarily uses gyro yaw.
  // Positive = turning right.
  double get lateralG => _lateralAccelMps2 / _gravityMetersPerSecondSquared;

  // Normalized "up" direction in device coordinates from the current
  // gravity estimate, or null if there isn't a usable one yet.
  List<double>? _currentUpAxis() {
    final gNorm = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    if (gNorm < 1e-6) return null; // no usable gravity reading yet
    return [_gx / gNorm, _gy / gNorm, _gz / gNorm];
  }

  // Feed one RAW accelerometer sample (gravity included). This stream is
  // used only to maintain the gyro-aided UP direction. It does NOT produce
  // live forward/lateral G as addUserAccelerometerSample does that from
  // the platform gravity-removed linear-acceleration stream.
  void addAccelerometerSample(AccelerometerEvent event) {
    final rawAccelMagnitude = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );
    if (!_hasGravityEstimate) {
      // The first reading establishes only DIRECTION. Force the magnitude to
      // standard g so initial linear acceleration cannot permanently change
      // the estimated gravity magnitude.
      if (rawAccelMagnitude < 1e-6) return;
      _gx = (event.x / rawAccelMagnitude) * _gravityMetersPerSecondSquared;
      _gy = (event.y / rawAccelMagnitude) * _gravityMetersPerSecondSquared;
      _gz = (event.z / rawAccelMagnitude) * _gravityMetersPerSecondSquared;
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
        final dtSeconds =
            event.timestamp.difference(previousCorrectionTime).inMicroseconds /
            1e6;
        if (dtSeconds > 0 && dtSeconds < 1.0) {
          final baseGain =
              1.0 -
              math.exp(-dtSeconds / _gravityAccelCorrectionTimeConstantSeconds);
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
  }

  List<double> _rotateVectorAroundAxis(
    List<double> vector,
    List<double> axis,
    double angleRadians,
  ) {
    final ax = axis[0], ay = axis[1], az = axis[2];
    final axisNorm = math.sqrt(ax * ax + ay * ay + az * az);
    if (axisNorm < 1e-9 || angleRadians.abs() < 1e-9) {
      return [vector[0], vector[1], vector[2]];
    }

    final ux = ax / axisNorm;
    final uy = ay / axisNorm;
    final uz = az / axisNorm;
    final c = math.cos(angleRadians);
    final s = math.sin(angleRadians);
    final oneMinusC = 1.0 - c;

    final vx = vector[0], vy = vector[1], vz = vector[2];
    return [
      (c + ux * ux * oneMinusC) * vx +
          (ux * uy * oneMinusC - uz * s) * vy +
          (ux * uz * oneMinusC + uy * s) * vz,
      (uy * ux * oneMinusC + uz * s) * vx +
          (c + uy * uy * oneMinusC) * vy +
          (uy * uz * oneMinusC - ux * s) * vz,
      (uz * ux * oneMinusC - uy * s) * vx +
          (uz * uy * oneMinusC + ux * s) * vy +
          (c + uz * uz * oneMinusC) * vz,
    ];
  }

  void _transportBasisForLargeUpChange(List<double> currentUp) {
    final forwardAxis = _forwardAxis;
    final previousUp = _basisUpAxis;
    if (forwardAxis == null || previousUp == null) return;

    final dotUp = (previousUp[0] * currentUp[0] +
            previousUp[1] * currentUp[1] +
            previousUp[2] * currentUp[2])
        .clamp(-1.0, 1.0);

    if (dotUp >= _basisTiltTransportThresholdCosine) return;

    // Near-180° UP reversal corresponds to the tested upright -> upside-down
    // portrait move. UP alone cannot determine the rotation path, while the
    // forward device axis can remain valid, so keep forward and simply re-anchor
    // UP; forward × currentUp gives the correct flipped lateral handedness.
    if (dotUp <= -0.95) {
      _basisUpAxis = [currentUp[0], currentUp[1], currentUp[2]];
      _lastForwardFilterTimestamp = null;
      _lastLateralFilterTimestamp = null;
      _pendingCalibrationSamples.clear();
      return;
    }

    final crossX =
        previousUp[1] * currentUp[2] - previousUp[2] * currentUp[1];
    final crossY =
        previousUp[2] * currentUp[0] - previousUp[0] * currentUp[2];
    final crossZ =
        previousUp[0] * currentUp[1] - previousUp[1] * currentUp[0];
    final crossNorm =
        math.sqrt(crossX * crossX + crossY * crossY + crossZ * crossZ);
    if (crossNorm < 1e-9) return;

    final angle = math.atan2(crossNorm, dotUp);
    final rotatedForward = _rotateVectorAroundAxis(
      forwardAxis,
      [crossX / crossNorm, crossY / crossNorm, crossZ / crossNorm],
      angle,
    );

    final rotatedNorm = math.sqrt(
      rotatedForward[0] * rotatedForward[0] +
          rotatedForward[1] * rotatedForward[1] +
          rotatedForward[2] * rotatedForward[2],
    );
    if (rotatedNorm > 1e-6) {
      _forwardAxis = [
        rotatedForward[0] / rotatedNorm,
        rotatedForward[1] / rotatedNorm,
        rotatedForward[2] / rotatedNorm,
      ];
      _basisUpAxis = [currentUp[0], currentUp[1], currentUp[2]];
      _lastForwardFilterTimestamp = null;
      _lastLateralFilterTimestamp = null;
      _pendingCalibrationSamples.clear();
    }
  }

  void _transportBasisForRelativeYaw(
    double relativeBasisYawRadians,
    List<double> currentUp,
  ) {
    final forwardAxis = _forwardAxis;
    if (forwardAxis == null ||
        relativeBasisYawRadians.abs() <
            _basisYawTransportThresholdRadians) {
      return;
    }

    // signed gyro yaw - GPS heading change equals the rotation of a fixed
    // vehicle vector in DEVICE coordinates caused by rotating the phone
    // relative to the vehicle. Apply that rotation directly to the saved basis.
    final rotatedForward = _rotateVectorAroundAxis(
      forwardAxis,
      currentUp,
      relativeBasisYawRadians,
    );

    final rotatedNorm = math.sqrt(
      rotatedForward[0] * rotatedForward[0] +
          rotatedForward[1] * rotatedForward[1] +
          rotatedForward[2] * rotatedForward[2],
    );
    if (rotatedNorm > 1e-6) {
      _forwardAxis = [
        rotatedForward[0] / rotatedNorm,
        rotatedForward[1] / rotatedNorm,
        rotatedForward[2] / rotatedNorm,
      ];
      _basisUpAxis = [currentUp[0], currentUp[1], currentUp[2]];
      _lastForwardFilterTimestamp = null;
      _lastLateralFilterTimestamp = null;
      _pendingCalibrationSamples.clear();
    }
  }

  // Feed one platform gravity-removed acceleration sample. This is the
  // authoritative source for live/calibration vehicle acceleration. Keeping
  // gravity removal in the platform sensor-fusion layer makes this path much
  // less sensitive to whether the device's X, Y, or Z axis happens to be
  // vertical (portrait, landscape, flat, upside-down, etc.).
  void addUserAccelerometerSample(UserAccelerometerEvent event) {
    if (!_hasGravityEstimate) return;

    final linX = event.x;
    final linY = event.y;
    final linZ = event.z;

    final axis = _currentUpAxis();
    if (axis == null) return; // practically unreachable so hold last known G

    _transportBasisForLargeUpChange(axis);

    final dx = axis[0], dy = axis[1], dz = axis[2];

    // UserAccelerometerEvent is already gravity-removed by the platform.
    // Remove any remaining VERTICAL vehicle/mount motion (bumps, suspension)
    // so calibration considers only the horizontal vehicle plane.
    final alongAxis = linX * dx + linY * dy + linZ * dz;
    final horizX = linX - alongAxis * dx;
    final horizY = linY - alongAxis * dy;
    final horizZ = linZ - alongAxis * dz;
    final horizontalMagSquared =
        horizX * horizX + horizY * horizY + horizZ * horizZ;

    // Buffer strong horizontal samples for the current GPS interval. Do NOT
    // perform the speed-dependent turn gate here: before forward calibration,
    // _estimatedSpeedMps may legitimately still be the last GPS speed. Instead
    // store the contemporaneous filtered gyro yaw rate with the sample. When
    // the interval closes, addGpsSample knows both endpoint GPS speeds and can
    // conservatively apply lateral ~= speed * yawRate using the higher one.
    if (horizontalMagSquared >=
        _minCalibrationHorizontalMps2 * _minCalibrationHorizontalMps2) {
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
            absYawRateRadPerSec: _filteredYawRateRadPerSec.abs(),
          ),
        );
        if (_pendingCalibrationSamples.length > _maxPendingCalibrationSamples) {
          _pendingCalibrationSamples.removeRange(
            0,
            _pendingCalibrationSamples.length - _maxPendingCalibrationSamples,
          );
        }
      }
    }

    final forwardAxis = _forwardAxis;
    if (forwardAxis == null) {
      // No confident calibration sample yet (see _updateForwardAxis):
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
    // per-sample correction on an otherwise-fixed axis.
    final rawFx = forwardAxis[0];
    final rawFy = forwardAxis[1];
    final rawFz = forwardAxis[2];
    final forwardAlongUp = rawFx * dx + rawFy * dy + rawFz * dz;
    final fx = rawFx - forwardAlongUp * dx;
    final fy = rawFy - forwardAlongUp * dy;
    final fz = rawFz - forwardAlongUp * dz;
    final fNorm = math.sqrt(fx * fx + fy * fy + fz * fz);
    if (fNorm < 1e-6) return; // practically unreachable so hold last known G
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
        final lateralDtSeconds =
            event.timestamp
                .difference(previousLateralFilterTime)
                .inMicroseconds /
            1e6;
        if (lateralDtSeconds > 0 && lateralDtSeconds < 1.0) {
          final lateralAlpha =
              1.0 -
              math.exp(-lateralDtSeconds / _outputFilterTimeConstantSeconds);
          _lateralAccelMps2 +=
              lateralAlpha * (rawLateralAccelMps2 - _lateralAccelMps2);
        } else {
          _lateralAccelMps2 = rawLateralAccelMps2;
        }
      }
    }

    // Forward G, directly: magnitude AND sign both fall out of one
    // projection of one measurement, at full accelerometer rate.
    // This never subtracts two independently-noisy numbers and
    // there's no separate, slower-updating sign to go stale.
    // Forward and lateral are direct projections of the same platform
    // gravity-removed acceleration vector onto an orthonormal vehicle basis.
    final forwardAccelMps2 = linX * nfx + linY * nfy + linZ * nfz;
    final rawForwardG = forwardAccelMps2 / _gravityMetersPerSecondSquared;

    // Mounts can physically ring/vibrate. Real braking/acceleration is
    // comparatively low frequency, so a short time-constant low-pass removes
    // mount buzz without introducing GPS-scale latency.
    final previousFilterTime = _lastForwardFilterTimestamp;
    _lastForwardFilterTimestamp = event.timestamp;
    if (previousFilterTime == null) {
      _forwardG = rawForwardG;
    } else {
      final dtSeconds =
          event.timestamp.difference(previousFilterTime).inMicroseconds / 1e6;
      if (dtSeconds > 0 && dtSeconds < 1.0) {
        final alpha =
            1.0 - math.exp(-dtSeconds / _outputFilterTimeConstantSeconds);
        _forwardG += alpha * (rawForwardG - _forwardG);
      } else {
        _forwardG = rawForwardG;
      }
    }
    _advanceEstimatedSpeed(event.timestamp);
  }

  // Dead-reckons speed between GPS fixes using forwardG. This is used only
  // by the gyro-derived temporary/pre-calibration lateral estimate and the
  // calibration turn gate. Post-calibration live lateral G is accelerometer-
  // derived and doesn't depend on speed. The estimate is resynced at every
  // GPS fix so integration error cannot compound across intervals.
  void _advanceEstimatedSpeed(DateTime sampleTime) {
    final previousTimestamp = _lastLinearAccelerationTimestamp;
    _lastLinearAccelerationTimestamp = sampleTime;
    final speedEstimate = _estimatedSpeedMps;
    if (previousTimestamp == null || speedEstimate == null) return;

    final dtSeconds =
        sampleTime.difference(previousTimestamp).inMicroseconds / 1e6;
    // Guard against duplicate/out-of-order samples and long gaps, same
    // idea as the gyro integral's own guard.
    if (dtSeconds <= 0 || dtSeconds >= 1.0) return;

    final forwardAccelForSpeedMps2 = _forwardG * _gravityMetersPerSecondSquared;
    _estimatedSpeedMps = math.max(
      0.0,
      speedEstimate + forwardAccelForSpeedMps2 * dtSeconds,
    );
  }

  // Snaps (on the first confident calibration) or slowly nudges
  // (thereafter) the calibrated forward axis toward an already-averaged,
  // already-signed candidate direction for a GPS interval that just
  // completed: see addGpsSample for how that candidate is assembled
  // (averaged from buffered accelerometer samples) and correctly
  // time-aligned with its sign (the interval's own GPS-derived speed
  // trend, not whatever sign was current when each sample arrived).
  void _updateForwardAxis(
    double candidateX,
    double candidateY,
    double candidateZ,
  ) {
    var candidateNorm = math.sqrt(
      candidateX * candidateX +
          candidateY * candidateY +
          candidateZ * candidateZ,
    );
    if (candidateNorm < 1e-6) return;

    candidateX /= candidateNorm;
    candidateY /= candidateNorm;
    candidateZ /= candidateNorm;

    final existing = _forwardAxis;
    if (existing == null) {
      // Do NOT let one GPS interval choose the sign of the entire vehicle
      // basis. A single delayed/noisy speed trend can be wrong even when the
      // accelerometer event itself is clean. Require two independent,
      // directionally-consistent intervals before publishing +forward.
      final pending = _pendingInitialForwardAxis;
      if (pending == null) {
        _pendingInitialForwardAxis = [candidateX, candidateY, candidateZ];
        _pendingInitialForwardAxisConfirmations = 1;
        return;
      }

      final agreement =
          pending[0] * candidateX +
          pending[1] * candidateY +
          pending[2] * candidateZ;

      if (agreement < _forwardAxisAgreementCosine) {
        // Conflicting evidence. Start confirmation again from the newest
        // candidate instead of averaging opposite directions into nonsense.
        _pendingInitialForwardAxis = [candidateX, candidateY, candidateZ];
        _pendingInitialForwardAxisConfirmations = 1;
        return;
      }

      var fx = pending[0] + candidateX;
      var fy = pending[1] + candidateY;
      var fz = pending[2] + candidateZ;
      final norm = math.sqrt(fx * fx + fy * fy + fz * fz);
      if (norm < 1e-6) {
        _pendingInitialForwardAxis = [candidateX, candidateY, candidateZ];
        _pendingInitialForwardAxisConfirmations = 1;
        return;
      }

      fx /= norm;
      fy /= norm;
      fz /= norm;
      _pendingInitialForwardAxis = [fx, fy, fz];
      _pendingInitialForwardAxisConfirmations++;

      if (_pendingInitialForwardAxisConfirmations >=
          _initialForwardAxisConfirmationsRequired) {
        _forwardAxis = [fx, fy, fz];
        final up = _currentUpAxis();
        if (up != null) {
          _basisUpAxis = [up[0], up[1], up[2]];
        }
        _pendingInitialForwardAxis = null;
        _pendingInitialForwardAxisConfirmations = 0;
      }
      return;
    }

    final existingDotCandidate =
        existing[0] * candidateX +
        existing[1] * candidateY +
        existing[2] * candidateZ;

    if (existingDotCandidate < _forwardAxisAgreementCosine) {
      // Large disagreement: never slowly EMA a 90°/180° remount into the old
      // basis, because the intermediate vector can literally mix/swap forward
      // and lateral. Confirm the new mounting with a second clean interval,
      // then snap directly.
      final pending = _pendingLargeRemountForwardAxis;
      if (pending == null) {
        _pendingLargeRemountForwardAxis = [
          candidateX,
          candidateY,
          candidateZ,
        ];
        _pendingLargeRemountForwardAxisConfirmations = 1;
        return;
      }

      final remountAgreement =
          pending[0] * candidateX +
          pending[1] * candidateY +
          pending[2] * candidateZ;

      if (remountAgreement < _forwardAxisAgreementCosine) {
        // Conflicting large-angle evidence: restart from the newest candidate.
        _pendingLargeRemountForwardAxis = [
          candidateX,
          candidateY,
          candidateZ,
        ];
        _pendingLargeRemountForwardAxisConfirmations = 1;
        return;
      }

      var fx = pending[0] + candidateX;
      var fy = pending[1] + candidateY;
      var fz = pending[2] + candidateZ;
      final norm = math.sqrt(fx * fx + fy * fy + fz * fz);
      if (norm < 1e-6) {
        _pendingLargeRemountForwardAxis = [
          candidateX,
          candidateY,
          candidateZ,
        ];
        _pendingLargeRemountForwardAxisConfirmations = 1;
        return;
      }

      fx /= norm;
      fy /= norm;
      fz /= norm;
      _pendingLargeRemountForwardAxis = [fx, fy, fz];
      _pendingLargeRemountForwardAxisConfirmations++;

      if (_pendingLargeRemountForwardAxisConfirmations >= 2) {
        _forwardAxis = [fx, fy, fz];
        final up = _currentUpAxis();
        if (up != null) {
          _basisUpAxis = [up[0], up[1], up[2]];
        }
        _pendingLargeRemountForwardAxis = null;
        _pendingLargeRemountForwardAxisConfirmations = 0;
        _lastForwardFilterTimestamp = null;
        _lastLateralFilterTimestamp = null;
      }
      return;
    }

    // Candidate agrees with the active mounting, so any unfinished large-remount
    // streak was spurious. Clear it and perform only a small normal refinement.
    _pendingLargeRemountForwardAxis = null;
    _pendingLargeRemountForwardAxisConfirmations = 0;

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
  // before the forward/lateral linear-acceleration basis has calibrated.
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
          var nextUx = ux + (uy * event.z - uz * event.y) * dtSeconds;
          var nextUy = uy + (uz * event.x - ux * event.z) * dtSeconds;
          var nextUz = uz + (ux * event.y - uy * event.x) * dtSeconds;
          final norm = math.sqrt(
            nextUx * nextUx + nextUy * nextUy + nextUz * nextUz,
          );
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
    // used for gravity removal: this is the car's yaw rate, in the
    // gyroscope's own (standard right-hand-rule) sign convention.
    final rawUpAxisRateRadPerSec = event.x * dx + event.y * dy + event.z * dz;

    // Flip sign to match lateralG's convention (positive = turning
    // right): standard GPS heading increases CLOCKWISE as seen from
    // above, which is a NEGATIVE rotation about the up axis by the
    // right-hand rule the gyroscope itself follows (unlike the
    // accelerometer, a gyroscope reports true angular velocity with no
    // extra sign quirk. This matches Android's own documented
    // convention: an observer positioned on the positive axis looking
    // back at the device sees a positive reading as counter-clockwise,
    // which for the "up" axis means a bird's-eye view from above, the
    // same viewpoint compass heading is defined from). So a right turn
    // reads as a NEGATIVE raw projection here, and needs negating to
    // read positive, matching lateralG.
    final signedYawRateRaw = -rawUpAxisRateRadPerSec;

    // Keep the RAW signed yaw rate. GPS bias correction later integrates
    // these timestamped samples over the exact GPS measurement interval rather
    // than whatever callback-to-callback window happened to occur.
    _pendingGyroSamples.add(
      _GyroSample(timestamp: now, signedYawRateRaw: signedYawRateRaw),
    );
    if (_pendingGyroSamples.length > _maxPendingGyroSamples) {
      _pendingGyroSamples.removeRange(
        0,
        _pendingGyroSamples.length - _maxPendingGyroSamples,
      );
    }

    final signedYawRateRadPerSec = signedYawRateRaw - _yawBiasRadPerSec;
    if (!_hasFilteredYawRate || gyroDtSeconds == null) {
      _filteredYawRateRadPerSec = signedYawRateRadPerSec;
      _hasFilteredYawRate = true;
    } else {
      final alpha =
          1.0 - math.exp(-gyroDtSeconds / _outputFilterTimeConstantSeconds);
      _filteredYawRateRadPerSec +=
          alpha * (signedYawRateRadPerSec - _filteredYawRateRadPerSec);
    }

    final currentSpeedMps = _estimatedSpeedMps ?? 0.0;
    _gyroLateralAccelMps2 = currentSpeedMps * _filteredYawRateRadPerSec;

    // Before the forward axis exists, this is the only mount-independent
    // lateral estimate available. Once calibrated, addUserAccelerometerSample
    // owns live lateral output so mount yaw wobble is no longer speed-amplified.
    if (_forwardAxis == null) {
      _lateralAccelMps2 = _gyroLateralAccelMps2;
    }
  }

  // Integrates raw signed gyro yaw rate over exactly [startTime, endTime].
  // Small boundary gaps are filled with the nearest sample's rate; any missing
  // coverage or internal gap larger than _maxGyroGapForBias rejects the whole
  // interval so a sensor dropout cannot masquerade as gyro bias.
  double? _integratedRawYawForGpsInterval(
    DateTime startTime,
    DateTime endTime,
  ) {
    final samples = <_GyroSample>[];
    for (final sample in _pendingGyroSamples) {
      if (!sample.timestamp.isBefore(startTime) &&
          !sample.timestamp.isAfter(endTime)) {
        samples.add(sample);
      }
    }
    if (samples.length < 2) return null;

    final first = samples.first;
    final last = samples.last;
    final startGap = first.timestamp.difference(startTime);
    final endGap = endTime.difference(last.timestamp);
    if (startGap.isNegative ||
        endGap.isNegative ||
        startGap > _maxGyroGapForBias ||
        endGap > _maxGyroGapForBias) {
      return null;
    }

    var integral = first.signedYawRateRaw * (startGap.inMicroseconds / 1e6);

    for (var i = 1; i < samples.length; i++) {
      final previous = samples[i - 1];
      final current = samples[i];
      final dt = current.timestamp.difference(previous.timestamp);
      if (dt.isNegative || dt == Duration.zero || dt > _maxGyroGapForBias) {
        return null;
      }
      final dtSeconds = dt.inMicroseconds / 1e6;
      integral +=
          0.5 *
          (previous.signedYawRateRaw + current.signedYawRateRaw) *
          dtSeconds;
    }

    integral += last.signedYawRateRaw * (endGap.inMicroseconds / 1e6);
    return integral;
  }

  // Establishes a fresh GPS measurement-time baseline: used both for the very
  // first accepted fix and whenever a gap is too long to trust a derivative
  // across it (see addGpsSample). Either way there is no valid prior interval,
  // so any buffered sensor evidence from before this timestamp is discarded
  // rather than risk labeling it against the wrong interval.
  void _resetGpsBaseline(
    double speedMps,
    double? headingDegrees,
    DateTime timestamp,
  ) {
    _lastGpsSpeedMps = speedMps;
    _lastGpsHeadingDegrees = headingDegrees;
    _lastGpsTimestamp = timestamp;
    _estimatedSpeedMps = speedMps;
    _pendingCalibrationSamples.removeWhere(
      (sample) => !sample.timestamp.isAfter(timestamp),
    );
    _pendingGyroSamples.removeWhere(
      (sample) => !sample.timestamp.isAfter(timestamp),
    );
  }

  // Feed one GPS fix. This is used only for (a) labeling the
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
      _resetGpsBaseline(speedMps, headingDegrees, timestamp);
      return;
    }

    // Use microseconds here too, matching the sensor paths. GPS itself is
    // coarse, but keeping one dt convention avoids needless quantization and
    // makes interval math consistent throughout the service.
    final dtSeconds =
        timestamp.difference(previousTimestamp).inMicroseconds / 1e6;

    // Truly ignore duplicate/out-of-order fixes
    if (dtSeconds <= 0.1) return;

    // A long gap cannot produce a trustworthy derivative. Treat this fix as a
    // fresh baseline, resync speed, and discard stale interval evidence rather
    // than trying to bridge the gap.
    if (dtSeconds > 5.0) {
      _resetGpsBaseline(speedMps, headingDegrees, timestamp);
      return;
    }

    // Integrate gyro over the SAME GPS measurement interval used below for
    // heading delta. null means coverage had a dropout/boundary hole, in which
    // case bias correction for this interval is deliberately skipped.
    final yawIntegralSinceLastFix = _integratedRawYawForGpsInterval(
      previousTimestamp,
      timestamp,
    );

    // Select calibration samples by SENSOR timestamp, not by callback order.
    // GPS delivery can be delayed. An accelerometer sample that arrives before
    // this callback may actually belong to the NEXT GPS interval.
    final intervalCalibrationSamples = <_CalibrationSample>[];
    final calibrationGateSpeedMps = math.max(previousSpeed, speedMps);
    for (final sample in _pendingCalibrationSamples) {
      if (sample.timestamp.isAfter(previousTimestamp) &&
          !sample.timestamp.isAfter(timestamp)) {
        // Use the higher GPS endpoint speed so acceleration during this interval
        // cannot make the lateral turn component look artificially small merely
        // because the previous GPS speed was stale. During braking this is also
        // conservative because previousSpeed is normally the larger endpoint.
        final lateralAtGateSpeedMps2 =
            calibrationGateSpeedMps * sample.absYawRateRadPerSec;
        if (lateralAtGateSpeedMps2.abs() <=
            _maxCalibrationLateralFraction * sample.magnitude) {
          intervalCalibrationSamples.add(sample);
        }
      }
    }
    // Everything at/before this GPS measurement time has now either been
    // consumed or deliberately rejected with this interval. Keep only newer
    // samples for the next fix.
    _pendingCalibrationSamples.removeWhere(
      (sample) => !sample.timestamp.isAfter(timestamp),
    );
    _pendingGyroSamples.removeWhere(
      (sample) => !sample.timestamp.isAfter(timestamp),
    );

    _lastGpsSpeedMps = speedMps;
    _lastGpsHeadingDegrees = headingDegrees;
    _lastGpsTimestamp = timestamp;
    // Resync the dead-reckoned speed estimate to GPS's own reading every
    // accepted fix so integration error never compounds beyond one interval.
    _estimatedSpeedMps = speedMps;

    final averageSpeed = (previousSpeed + speedMps) / 2;

    // Forward-axis calibration:
    // Below _minForwardCalibrationSpeedMps, or when the speed change is too
    // small, GPS direction ambiguity/noise dominates. Skip the interval rather
    // than risk a mislabeled polarity sample.
    if (averageSpeed >= _minForwardCalibrationSpeedMps) {
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
              _minCalibrationHorizontalMps2 * _minCalibrationHorizontalMps2) {
            final avgMag = math.sqrt(avgMagSquared);

            // GPS contributes only the + / - LABEL. If its measured dv/dt is
            // tiny compared with this strong, coherent linear-acceleration
            // event, that label is vulnerable to GPS noise/lag and is safer to
            // discard than to mirror the whole vehicle basis.
            final gpsToLinearAccelRatio = yForward.abs() / avgMag;
            if (gpsToLinearAccelRatio >= _minGpsToLinearAccelCalibrationRatio) {
              // UserAccelerometerEvent follows actual device acceleration:
              // accelerating points forward and braking points backward.
              // Multiplying by GPS's interval sign therefore yields a
              // consistently +forward candidate in either case.
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
    }

    // Gyro-vs-GPS yaw comparison has two uses:
    //  1) a LARGE disagreement means the PHONE rotated around UP relative to
    //     the vehicle, so transport the already-calibrated basis;
    //  2) a small residual disagreement is ordinary gyro bias.
    final headingAccuracyOk =
        headingAccuracyDegrees == null ||
        (headingAccuracyDegrees >= 0 &&
            headingAccuracyDegrees <= _maxTrustedHeadingAccuracyDegrees);
    if (headingDegrees != null &&
        previousHeading != null &&
        averageSpeed >= _minHeadingSpeedMps &&
        headingAccuracyOk &&
        yawIntegralSinceLastFix != null) {
      var headingDeltaDegrees = headingDegrees - previousHeading;
      headingDeltaDegrees =
          ((headingDeltaDegrees + 180) % 360 + 360) % 360 - 180;
      final actualSignedHeadingDeltaRad = headingDeltaDegrees * math.pi / 180;

      final relativeBasisYawRadians =
          yawIntegralSinceLastFix - actualSignedHeadingDeltaRad;

      final currentUp = _currentUpAxis();
      final hadLargeRelativeYaw =
          _forwardAxis != null &&
          currentUp != null &&
          relativeBasisYawRadians.abs() >=
              _basisYawTransportThresholdRadians;

      if (hadLargeRelativeYaw) {
        _transportBasisForRelativeYaw(relativeBasisYawRadians, currentUp);
      } else {
        // A remount is real phone motion, not sensor bias. Only small residuals
        // are allowed to teach the slow gyro-bias estimator.
        final observedBias =
            (yawIntegralSinceLastFix - actualSignedHeadingDeltaRad) / dtSeconds;
        _yawBiasRadPerSec +=
            _gyroBiasLearningRate * (observedBias - _yawBiasRadPerSec);
      }
    }

  }
}

class _GyroSample {
  const _GyroSample({required this.timestamp, required this.signedYawRateRaw});

  final DateTime timestamp;
  final double signedYawRateRaw;
}

class _CalibrationSample {
  const _CalibrationSample({
    required this.timestamp,
    required this.x,
    required this.y,
    required this.z,
    required this.magnitude,
    required this.absYawRateRadPerSec,
  });

  final DateTime timestamp;
  final double x, y, z;
  final double magnitude;

  // Most recent filtered gyro yaw magnitude when this acceleration sample was
  // received. Speed is deliberately NOT baked in here; addGpsSample applies the
  // interval's actual endpoint speed after the interval closes.
  final double absYawRateRadPerSec;
}
