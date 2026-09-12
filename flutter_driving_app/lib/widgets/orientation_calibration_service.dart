// Decides forward/lateral vehicle-frame acceleration from the phone's
// raw accelerometer and gyroscope, regardless of how the phone happens to
// be mounted.
//
// 1. Gyro-aided gravity / tilt direction.
//    The accelerometer supplies an absolute long-term reference for the
//    phone's "up" direction, while the gyroscope propagates that direction at
//    full sensor rate as the phone/car pitches and rolls. This up
//    estimate is used only to define the horizontal vehicle plane as live
//    vehicle acceleration comes from sensors_plus UserAccelerometerEvent,
//    whose platform sensor has gravity removed already. That avoids turning a
//    small gravity-estimation error into fake forward/lateral G, which proves
//    especially important when the phone is physically landscape.
//    The absolute reference is (raw accelerometer - platform gravity-removed
//    acceleration), which isolates gravity directly instead of assuming
//    vehicle acceleration averages out of the raw signal. Sustained
//    acceleration therefore no longer has to freeze the correction, so gyro
//    tilt drift keeps getting cleaned up during exactly the events being
//    graded. The old motion-gated raw-accelerometer path remains as a fallback
//    for devices/moments where a fresh gravity-removed sample isn't available.
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
// half needs enough confident, directionally-consistent calibration evidence
// before it reports anything other than 0: two ordinary qualifying intervals,
// or a single interval that clears every gate by a wide margin: see
// _forwardAxis, _candidateConfidenceWeight and _updateForwardAxis.
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
//  - forwardG reads 0 until directionally-consistent calibration evidence
//    establishes the initial axis. Candidate admission is intentionally permissive
//    enough for ordinary deliberate accel/brake events, which each carry half the
//    required confidence so two independent intervals still have to agree before
//    a marginal GPS polarity label is trusted. Only an interval that is clean on
//    every axis at once (coherence, GPS speed change, GPS-to-accelerometer ratio
//    and qualifying span) carries full confidence and calibrates on its own,
//    which is what makes a deliberate hard acceleration or stop calibrate the
//    trip roughly a GPS interval sooner than the old fixed two-interval rule.
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
//    Unconfirmed candidates (initial-calibration evidence and large-remount
//    evidence) are device-frame vectors too, so they are transported by the same
//    rotation rather than left describing the previous mounting. A remount part
//    way through initial calibration therefore keeps its progress.
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
//    low-pass filtered before grading/display. That filter is deviation-aware:
//    it keeps the long smoothing time constant while the signal is steady and
//    shortens it while the signal is genuinely moving, so mount buzz is still
//    suppressed but the peak of a real brake/turn is neither flattened nor
//    delayed the way a single fixed time constant flattens it.
import 'dart:math' as math;
import 'package:sensors_plus/sensors_plus.dart';

class OrientationCalibrationService {
  OrientationCalibrationService({
    this._gravityAccelCorrectionTimeConstantSeconds =
        1.5, // accel slowly removes gyro tilt drift when the phone is not under strong linear acceleration
    this._gravityMotionGateReferenceMps2 =
        0.5, // above ~0.05g residual, trust gyro propagation increasingly more than accelerometer direction
    this._gravityLinearCorrectionTimeConstantSeconds =
        0.4, // (raw - gravity-removed) already isolates gravity, so it can be trusted far faster than the motion-gated raw signal
    this._maxLinearAccelPairingAge = const Duration(
      milliseconds: 120,
    ), // beyond this the gravity-removed sample is too stale to subtract from a raw sample
    this._maxGravityMagnitudeErrorFraction =
        0.25, // reject (raw - gravity-removed) when it isn't within 25% of g, i.e. the two streams momentarily disagree
    this._outputFilterTimeConstantSeconds =
        0.12, // suppress mount/road vibration while the signal is steady
    this._outputFilterFastTimeConstantSeconds =
        0.04, // used while the signal is genuinely moving, so real peaks are not flattened or delayed
    this._outputFilterTransitionG =
        0.1, // deviation from the filtered value at which the filter is fully switched to its fast time constant
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
    this._ordinaryCandidateConfidenceWeight =
        0.5, // an interval that merely clears the gates is worth half the initial lock, so two of them are still required
    this._excellentCalibrationCoherence =
        0.95, // coherence at which an interval's direction evidence counts as unambiguous
    this._excellentGpsToLinearAccelRatio =
        0.55, // GPS-vs-accelerometer agreement at which the polarity label counts as unambiguous
    this._excellentForwardSignalMps2 =
        1.2, // GPS speed change at which the +/- label is far too large to be noise or lag
    this._excellentCalibrationDuration = const Duration(
      milliseconds: 500,
    ), // qualifying span at which the event is clearly deliberate driving rather than a brief blip
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

  // Total confidence weight required before the initial forward axis is
  // published. Ordinary intervals contribute _ordinaryCandidateConfidenceWeight
  // each; an interval clean on every gate at once contributes all of it.
  static const double _initialForwardAxisConfidenceRequired = 1.0;

  final double _gravityAccelCorrectionTimeConstantSeconds;
  final double _gravityMotionGateReferenceMps2;
  final double _gravityLinearCorrectionTimeConstantSeconds;
  final Duration _maxLinearAccelPairingAge;
  final double _maxGravityMagnitudeErrorFraction;
  final double _outputFilterTimeConstantSeconds;
  final double _outputFilterFastTimeConstantSeconds;
  final double _outputFilterTransitionG;
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
  final double _ordinaryCandidateConfidenceWeight;
  final double _excellentCalibrationCoherence;
  final double _excellentGpsToLinearAccelRatio;
  final double _excellentForwardSignalMps2;
  final Duration _excellentCalibrationDuration;
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

  // Most recent platform gravity-removed sample. Subtracting it from a raw
  // accelerometer sample of the same moment leaves gravity by itself, which is
  // a far better absolute UP reference than the raw signal: it stays valid
  // during sustained braking/acceleration instead of having to be gated out.
  double _lastLinearAccelX = 0;
  double _lastLinearAccelY = 0;
  double _lastLinearAccelZ = 0;
  DateTime? _lastLinearAccelTimestamp;

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
  // Confidence accumulates rather than counting intervals, so ordinary evidence
  // still needs a second agreeing interval while unambiguous evidence does not.
  List<double>? _pendingInitialForwardAxis;
  double _pendingInitialForwardAxisConfidence = 0;

  // If a clean GPS-labelled candidate differs from the active device-frame
  // forward axis by more than ~41 degrees, the phone was probably remounted
  // (including yaw-only remounts that happened while GPS heading was unusable).
  // Require a second mutually-consistent candidate before snapping to that new
  // mounting so one bad GPS derivative cannot rotate/swap the whole basis.
  List<double>? _pendingLargeRemountForwardAxis;
  double _pendingLargeRemountForwardAxisConfidence = 0;

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
  // unavailable instead of presenting an unexplained dash. Confidence is
  // reported in units of an ordinary qualifying interval, so a single
  // unambiguous event can move this straight from 0/2 to calibrated.
  int get forwardCalibrationConfirmations => _forwardAxis != null
      ? forwardCalibrationConfirmationsRequired
      : (_pendingInitialForwardAxisConfidence /
                _ordinaryCandidateConfidenceWeight)
            .floor()
            .clamp(0, forwardCalibrationConfirmationsRequired);
  int get forwardCalibrationConfirmationsRequired =>
      (_initialForwardAxisConfidenceRequired /
              _ordinaryCandidateConfidenceWeight)
          .round();

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

  // Gravity by itself, in device coordinates, obtained by removing the
  // platform's own linear-acceleration estimate from this raw sample. Null when
  // the gravity-removed stream has nothing fresh enough to pair with, or when
  // the two streams momentarily disagree by more than a plausible gravity
  // magnitude error. Unlike the raw signal, this reference stays valid during
  // sustained braking and acceleration, which is exactly when the raw signal is
  // mostly vehicle motion and has to be gated out.
  List<double>? _isolatedGravityDirection(AccelerometerEvent event) {
    final linearTimestamp = _lastLinearAccelTimestamp;
    if (linearTimestamp == null) return null;

    final pairingAge = event.timestamp.difference(linearTimestamp).abs();
    if (pairingAge > _maxLinearAccelPairingAge) return null;

    final gravityX = event.x - _lastLinearAccelX;
    final gravityY = event.y - _lastLinearAccelY;
    final gravityZ = event.z - _lastLinearAccelZ;
    final magnitude = math.sqrt(
      gravityX * gravityX + gravityY * gravityY + gravityZ * gravityZ,
    );
    if (magnitude < 1e-6) return null;

    // These are two separate platform sensors, so a mispaired or differently
    // filtered sample shows up as a residual that is not gravity-sized. Those
    // are dropped rather than allowed to rotate the estimate.
    final magnitudeError =
        (magnitude - _gravityMetersPerSecondSquared).abs() /
        _gravityMetersPerSecondSquared;
    if (magnitudeError > _maxGravityMagnitudeErrorFraction) return null;

    return [gravityX / magnitude, gravityY / magnitude, gravityZ / magnitude];
  }

  // How much of the raw accelerometer direction to believe. The gyro (see
  // addGyroscopeSample) already follows FAST tilt changes, so the raw signal is
  // only the long-term absolute reference, and it is gated aggressively whenever
  // it disagrees with predicted gravity, because that disagreement is usually
  // vehicle acceleration or mount vibration rather than a reason to rotate the
  // gravity estimate. Only used when gravity could not be isolated directly.
  double _rawAccelMotionGate(AccelerometerEvent event) {
    final apparentMotion = math.sqrt(
      (event.x - _gx) * (event.x - _gx) +
          (event.y - _gy) * (event.y - _gy) +
          (event.z - _gz) * (event.z - _gz),
    );
    final ratio = apparentMotion / _gravityMotionGateReferenceMps2;
    final ratioSquared = ratio * ratio;
    return 1.0 / (1.0 + ratioSquared * ratioSquared);
  }

  // Feed one RAW accelerometer sample (gravity included). This stream is
  // used only to maintain the gyro-aided UP direction. It does NOT produce
  // live forward/lateral G as addUserAccelerometerSample does that from
  // the platform gravity-removed linear-acceleration stream.
  void addAccelerometerSample(AccelerometerEvent event) {
    final isolatedGravity = _isolatedGravityDirection(event);
    final rawAccelMagnitude = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );

    if (!_hasGravityEstimate) {
      // The first reading establishes only DIRECTION. Force the magnitude to
      // standard g so initial linear acceleration cannot permanently change
      // the estimated gravity magnitude.
      final List<double> initialUp;
      if (isolatedGravity != null) {
        initialUp = isolatedGravity;
      } else if (rawAccelMagnitude >= 1e-6) {
        initialUp = [
          event.x / rawAccelMagnitude,
          event.y / rawAccelMagnitude,
          event.z / rawAccelMagnitude,
        ];
      } else {
        return;
      }
      _gx = initialUp[0] * _gravityMetersPerSecondSquared;
      _gy = initialUp[1] * _gravityMetersPerSecondSquared;
      _gz = initialUp[2] * _gravityMetersPerSecondSquared;
      _hasGravityEstimate = true;
      _lastGravityAccelCorrectionTimestamp = event.timestamp;
      return;
    }

    // Isolated gravity is believed fully, and on a much shorter time constant,
    // because vehicle acceleration has already been taken out of it. The raw
    // fallback keeps the old slow, motion-gated behavior.
    final List<double> measuredUp;
    final double correctionTimeConstantSeconds;
    final double trust;
    if (isolatedGravity != null) {
      measuredUp = isolatedGravity;
      correctionTimeConstantSeconds =
          _gravityLinearCorrectionTimeConstantSeconds;
      trust = 1.0;
    } else if (rawAccelMagnitude >= 1e-6) {
      measuredUp = [
        event.x / rawAccelMagnitude,
        event.y / rawAccelMagnitude,
        event.z / rawAccelMagnitude,
      ];
      correctionTimeConstantSeconds =
          _gravityAccelCorrectionTimeConstantSeconds;
      trust = _rawAccelMotionGate(event);
    } else {
      return;
    }

    final previousCorrectionTime = _lastGravityAccelCorrectionTimestamp;
    _lastGravityAccelCorrectionTimestamp = event.timestamp;
    if (previousCorrectionTime == null) return;

    final dtSeconds =
        event.timestamp.difference(previousCorrectionTime).inMicroseconds / 1e6;
    if (dtSeconds <= 0 || dtSeconds >= 1.0) return;

    final currentAxis = _currentUpAxis();
    if (currentAxis == null) return;

    final gain =
        (1.0 - math.exp(-dtSeconds / correctionTimeConstantSeconds)) * trust;
    var ux = currentAxis[0] + gain * (measuredUp[0] - currentAxis[0]);
    var uy = currentAxis[1] + gain * (measuredUp[1] - currentAxis[1]);
    var uz = currentAxis[2] + gain * (measuredUp[2] - currentAxis[2]);
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

  // True while any device-frame forward evidence exists, confirmed or not.
  // Unconfirmed evidence describes the mounting it was measured in, so it has
  // to be transported by a remount exactly like the confirmed basis.
  bool get _hasForwardEvidence =>
      _forwardAxis != null ||
      _pendingInitialForwardAxis != null ||
      _pendingLargeRemountForwardAxis != null;

  List<double>? _rotatedUnitVector(
    List<double>? vector,
    List<double> axis,
    double angleRadians,
  ) {
    if (vector == null) return null;
    final rotated = _rotateVectorAroundAxis(vector, axis, angleRadians);
    final norm = math.sqrt(
      rotated[0] * rotated[0] +
          rotated[1] * rotated[1] +
          rotated[2] * rotated[2],
    );
    if (norm < 1e-6) return vector;
    return [rotated[0] / norm, rotated[1] / norm, rotated[2] / norm];
  }

  // Re-expresses every stored device-frame vector in the phone's new coordinate
  // frame and re-anchors UP. Buffered acceleration samples and the output
  // filters belong to the old mounting, so they are dropped rather than mixed
  // across the remount.
  void _applyBasisTransport(
    List<double> currentUp, {
    List<double>? rotationAxis,
    double rotationAngleRadians = 0.0,
  }) {
    if (rotationAxis != null && rotationAngleRadians.abs() > 1e-9) {
      _forwardAxis = _rotatedUnitVector(
        _forwardAxis,
        rotationAxis,
        rotationAngleRadians,
      );
      _pendingInitialForwardAxis = _rotatedUnitVector(
        _pendingInitialForwardAxis,
        rotationAxis,
        rotationAngleRadians,
      );
      _pendingLargeRemountForwardAxis = _rotatedUnitVector(
        _pendingLargeRemountForwardAxis,
        rotationAxis,
        rotationAngleRadians,
      );
    }

    _basisUpAxis = [currentUp[0], currentUp[1], currentUp[2]];
    _lastForwardFilterTimestamp = null;
    _lastLateralFilterTimestamp = null;
    _pendingCalibrationSamples.clear();
  }

  void _transportBasisForLargeUpChange(List<double> currentUp) {
    final previousUp = _basisUpAxis;
    if (!_hasForwardEvidence || previousUp == null) return;

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
      _applyBasisTransport(currentUp);
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

    _applyBasisTransport(
      currentUp,
      rotationAxis: [
        crossX / crossNorm,
        crossY / crossNorm,
        crossZ / crossNorm,
      ],
      rotationAngleRadians: math.atan2(crossNorm, dotUp),
    );
  }

  void _transportBasisForRelativeYaw(
    double relativeBasisYawRadians,
    List<double> currentUp,
  ) {
    if (!_hasForwardEvidence ||
        relativeBasisYawRadians.abs() <
            _basisYawTransportThresholdRadians) {
      return;
    }

    // signed gyro yaw - GPS heading change equals the rotation of a fixed
    // vehicle vector in DEVICE coordinates caused by rotating the phone
    // relative to the vehicle. Apply that rotation directly to the saved basis.
    _applyBasisTransport(
      currentUp,
      rotationAxis: currentUp,
      rotationAngleRadians: relativeBasisYawRadians,
    );
  }

  // Feed one platform gravity-removed acceleration sample. This is the
  // authoritative source for live/calibration vehicle acceleration. Keeping
  // gravity removal in the platform sensor-fusion layer makes this path much
  // less sensitive to whether the device's X, Y, or Z axis happens to be
  // vertical (portrait, landscape, flat, upside-down, etc.).
  void addUserAccelerometerSample(UserAccelerometerEvent event) {
    final linX = event.x;
    final linY = event.y;
    final linZ = event.z;

    // Kept even before there is a gravity estimate, since the raw
    // accelerometer path uses it to isolate gravity on its very first sample.
    _lastLinearAccelX = linX;
    _lastLinearAccelY = linY;
    _lastLinearAccelZ = linZ;
    _lastLinearAccelTimestamp = event.timestamp;

    if (!_hasGravityEstimate) return;

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
      _lateralAccelMps2 = _filterOutput(
        filtered: _lateralAccelMps2,
        raw: rawLateralAccelMps2,
        previousFilterTime: previousLateralFilterTime,
        sampleTime: event.timestamp,
        transitionScale:
            _outputFilterTransitionG * _gravityMetersPerSecondSquared,
      );
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
    _forwardG = _filterOutput(
      filtered: _forwardG,
      raw: rawForwardG,
      previousFilterTime: previousFilterTime,
      sampleTime: event.timestamp,
      transitionScale: _outputFilterTransitionG,
    );
    _advanceEstimatedSpeed(event.timestamp);
  }

  // Low-pass filter for a published G axis, with a deviation-dependent time
  // constant. A single fixed time constant has to choose between suppressing
  // mount buzz and reporting the true size of a real event: it always lags and
  // under-reports the peak of a genuine brake/turn by roughly its own time
  // constant. Vibration is small and alternates around the current value while
  // a real event is a large, one-directional departure from it, so the size of
  // the deviation separates the two. Steady signals keep the long time
  // constant; deviations at or beyond [transitionScale] get the short one.
  double _filterOutput({
    required double filtered,
    required double raw,
    required DateTime? previousFilterTime,
    required DateTime sampleTime,
    required double transitionScale,
  }) {
    if (previousFilterTime == null) return raw;

    final dtSeconds =
        sampleTime.difference(previousFilterTime).inMicroseconds / 1e6;
    // Duplicate/out-of-order samples and long gaps carry no usable filter
    // history, same guard as the other integrators in this service.
    if (dtSeconds <= 0 || dtSeconds >= 1.0) return raw;

    final responsiveness = transitionScale > 1e-9
        ? ((raw - filtered).abs() / transitionScale).clamp(0.0, 1.0)
        : 1.0;
    final timeConstantSeconds =
        _outputFilterTimeConstantSeconds +
        (_outputFilterFastTimeConstantSeconds -
                _outputFilterTimeConstantSeconds) *
            responsiveness;

    final alpha = 1.0 - math.exp(-dtSeconds / timeConstantSeconds);
    return filtered + alpha * (raw - filtered);
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

  // Records the UP direction the currently stored device-frame vectors were
  // measured against, which is what later lets a remount be detected as a
  // change of frame instead of a change of vehicle motion.
  void _rememberBasisUpAxis() {
    final up = _currentUpAxis();
    if (up != null) {
      _basisUpAxis = [up[0], up[1], up[2]];
    }
  }

  // How much of the initial (or post-remount) forward-axis confidence one
  // completed GPS interval is worth. An interval that merely clears the gates is
  // worth _ordinaryCandidateConfidenceWeight, so two agreeing intervals are
  // still needed before a marginal polarity label is trusted. An interval that
  // clears every gate by a wide margin at the same time (very coherent
  // acceleration, a GPS speed change far too large to be noise or lag, close
  // agreement between the GPS and accelerometer magnitudes, and a qualifying
  // span long enough to be deliberate driving) is worth the whole requirement,
  // so one clean hard acceleration or stop calibrates without waiting for a
  // second interval. Taking the minimum across the factors means one weak
  // dimension is enough to fall back to needing confirmation.
  double _candidateConfidenceWeight({
    required double coherence,
    required double requiredCoherence,
    required double gpsToLinearAccelRatio,
    required double gpsSignalMps2,
    required Duration qualifyingSpan,
  }) {
    double excess(double value, double ordinary, double excellent) {
      if (excellent <= ordinary) return 1.0;
      return ((value - ordinary) / (excellent - ordinary)).clamp(0.0, 1.0);
    }

    final quality = [
      excess(coherence, requiredCoherence, _excellentCalibrationCoherence),
      excess(
        gpsToLinearAccelRatio,
        _minGpsToLinearAccelCalibrationRatio,
        _excellentGpsToLinearAccelRatio,
      ),
      excess(gpsSignalMps2, _minForwardSignalMps2, _excellentForwardSignalMps2),
      excess(
        qualifyingSpan.inMicroseconds / 1e6,
        _minCalibrationDuration.inMicroseconds / 1e6,
        _excellentCalibrationDuration.inMicroseconds / 1e6,
      ),
    ].reduce(math.min);

    return _ordinaryCandidateConfidenceWeight +
        (_initialForwardAxisConfidenceRequired -
                _ordinaryCandidateConfidenceWeight) *
            quality;
  }

  // Snaps (once enough confidence has accumulated) or slowly nudges
  // (thereafter) the calibrated forward axis toward an already-averaged,
  // already-signed candidate direction for a GPS interval that just
  // completed: see addGpsSample for how that candidate is assembled
  // (averaged from buffered accelerometer samples) and correctly
  // time-aligned with its sign (the interval's own GPS-derived speed
  // trend, not whatever sign was current when each sample arrived).
  // candidateConfidence is how much that interval is worth, from
  // _candidateConfidenceWeight.
  void _updateForwardAxis(
    double candidateX,
    double candidateY,
    double candidateZ,
    double candidateConfidence,
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
      // Do NOT let one MARGINAL GPS interval choose the sign of the entire
      // vehicle basis. A delayed/noisy speed trend can be wrong even when the
      // accelerometer event itself is clean, so ordinary evidence only carries
      // part of the required confidence and a second, directionally-consistent
      // interval has to agree. Evidence that is unambiguous on every gate at
      // once (see _candidateConfidenceWeight) carries all of it, which is what
      // lets a deliberate hard acceleration or stop calibrate immediately.
      var axisX = candidateX;
      var axisY = candidateY;
      var axisZ = candidateZ;
      var confidence = candidateConfidence;

      final pending = _pendingInitialForwardAxis;
      if (pending != null) {
        final agreement =
            pending[0] * candidateX +
            pending[1] * candidateY +
            pending[2] * candidateZ;

        // Conflicting evidence starts over from the newest candidate instead of
        // averaging opposite directions into nonsense.
        if (agreement >= _forwardAxisAgreementCosine) {
          final pendingConfidence = _pendingInitialForwardAxisConfidence;
          // Weighted by confidence so the cleaner interval has more say in the
          // direction the axis ends up snapping to.
          var fx =
              pending[0] * pendingConfidence + candidateX * candidateConfidence;
          var fy =
              pending[1] * pendingConfidence + candidateY * candidateConfidence;
          var fz =
              pending[2] * pendingConfidence + candidateZ * candidateConfidence;
          final norm = math.sqrt(fx * fx + fy * fy + fz * fz);
          if (norm >= 1e-6) {
            axisX = fx / norm;
            axisY = fy / norm;
            axisZ = fz / norm;
            confidence = pendingConfidence + candidateConfidence;
          }
        }
      }

      // Anchor UP against the frame this evidence was measured in. Doing it for
      // partial evidence too means a remount part way through calibration
      // transports that progress instead of leaving it describing the old
      // mounting.
      _rememberBasisUpAxis();

      if (confidence >= _initialForwardAxisConfidenceRequired) {
        _forwardAxis = [axisX, axisY, axisZ];
        _pendingInitialForwardAxis = null;
        _pendingInitialForwardAxisConfidence = 0;
      } else {
        _pendingInitialForwardAxis = [axisX, axisY, axisZ];
        _pendingInitialForwardAxisConfidence = confidence;
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
      // and lateral. Confirm the new mounting the same way the initial axis is
      // confirmed (ordinary evidence needs a second agreeing interval, evidence
      // that is clean on every gate stands alone), then snap directly.
      var axisX = candidateX;
      var axisY = candidateY;
      var axisZ = candidateZ;
      var confidence = candidateConfidence;

      final pending = _pendingLargeRemountForwardAxis;
      if (pending != null) {
        final remountAgreement =
            pending[0] * candidateX +
            pending[1] * candidateY +
            pending[2] * candidateZ;

        // Conflicting large-angle evidence restarts from the newest candidate.
        if (remountAgreement >= _forwardAxisAgreementCosine) {
          final pendingConfidence = _pendingLargeRemountForwardAxisConfidence;
          var fx =
              pending[0] * pendingConfidence + candidateX * candidateConfidence;
          var fy =
              pending[1] * pendingConfidence + candidateY * candidateConfidence;
          var fz =
              pending[2] * pendingConfidence + candidateZ * candidateConfidence;
          final norm = math.sqrt(fx * fx + fy * fy + fz * fz);
          if (norm >= 1e-6) {
            axisX = fx / norm;
            axisY = fy / norm;
            axisZ = fz / norm;
            confidence = pendingConfidence + candidateConfidence;
          }
        }
      }

      if (confidence >= _initialForwardAxisConfidenceRequired) {
        _forwardAxis = [axisX, axisY, axisZ];
        _rememberBasisUpAxis();
        _pendingLargeRemountForwardAxis = null;
        _pendingLargeRemountForwardAxisConfidence = 0;
        // The published axis just moved a long way, so the filtered outputs
        // describe the previous mounting and are restarted rather than blended.
        _lastForwardFilterTimestamp = null;
        _lastLateralFilterTimestamp = null;
      } else {
        _pendingLargeRemountForwardAxis = [axisX, axisY, axisZ];
        _pendingLargeRemountForwardAxisConfidence = confidence;
      }
      return;
    }

    // Candidate agrees with the active mounting, so any unfinished large-remount
    // streak was spurious. Clear it and perform only a small normal refinement.
    _pendingLargeRemountForwardAxis = null;
    _pendingLargeRemountForwardAxisConfidence = 0;

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
                _candidateConfidenceWeight(
                  coherence: coherence,
                  requiredCoherence: requiredCoherence,
                  gpsToLinearAccelRatio: gpsToLinearAccelRatio,
                  gpsSignalMps2: yForward.abs(),
                  qualifyingSpan: qualifyingSpan,
                ),
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
          _hasForwardEvidence &&
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
