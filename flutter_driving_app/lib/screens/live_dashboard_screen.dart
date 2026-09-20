// Shown while a trip is in progress. Tracks elapsed time, distance driven,
// current speed, the posted speed limit, and live driving grades.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../widgets/background_location_service.dart';
import '../widgets/speed_grading_service.dart';
import '../widgets/speed_limit_service.dart';
import '../widgets/smoothness_grading_service.dart';
import '../widgets/focused_driving_grading_service.dart';
import '../widgets/orientation_calibration_service.dart';
import '../widgets/trip_summary.dart';
import '../widgets/auth_storage.dart';
import 'driving_report_screen.dart';

// Formats a duration as mm:ss, or hh:mm:ss if over an hour
String formatElapsed(Duration d) {
  String twoDigits(int n) => n.toString().padLeft(2, '0');
  final hours = twoDigits(d.inHours);
  final minutes = twoDigits(d.inMinutes.remainder(60));
  final seconds = twoDigits(d.inSeconds.remainder(60));
  if (d.inHours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

// Color for a grade: green if good, orange if ok, red if bad
Color gradeColor(double grade) {
  if (grade >= 90) {
    return Colors.green;
  }
  if (grade >= 70) {
    return Colors.orange;
  }
  return Colors.red;
}

class LiveDashboardScreen extends StatefulWidget {
  const LiveDashboardScreen({super.key});

  @override
  State<LiveDashboardScreen> createState() => _LiveDashboardScreenState();
}

class _LiveDashboardScreenState extends State<LiveDashboardScreen>
    with WidgetsBindingObserver {
  static const double _metersToMiles = 0.000621371;
  static const double _metersPerSecondToMph = 2.23694;

  // How often to refresh the posted speed limit
  static const Duration _speedLimitRefreshInterval = Duration(seconds: 4);

  // Below this speed, ignore distance/movement to avoid GPS jitter
  static const double _minSpeedForDistanceMph = 3.0;
  static const double _minSpeedMph = 3.0;

  // Ignore speed updates with worse accuracy than this
  static const double _maxTrustedSpeedAccuracyMps = 1.5;
  static const double _maxSpeedDisagreementMph = 10.0;
  static const double _maxTrustedHorizontalAccuracyMeters = 25.0;

  // Flag speed red once it's this much over the limit
  static const double _speedingThresholdMph = 5.0;

  // Smoothing factor for displayed speed. 0 = never update, 1 = no smoothing.
  static const double _speedSmoothingAlpha = 1;

  final DateTime _tripStartTime = DateTime.now();
  final SpeedGradingService _properSpeedGrading = SpeedGradingService();
  final SmoothnessGradingService _smoothnessGrading =
      SmoothnessGradingService();
  final OrientationCalibrationService _orientationCalibration =
      OrientationCalibrationService();
  final FocusedDrivingGradingService _focusedDrivingGrading =
      FocusedDrivingGradingService();

  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  StreamSubscription<UserAccelerometerEvent>? _userAccelerometerSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroscopeSubscription;
  Timer? _elapsedTimer;

  Duration _elapsed = Duration.zero;
  double _milesDriven = 0;
  double _currentSpeedMph = 0;
  double _smoothedSpeedMph = 0;
  double? _postedSpeedLimitMph;

  Position? _lastPosition;
  DateTime? _lastSpeedLimitFetchTime;
  bool _isFetchingSpeedLimit = false;

  bool _receivedFirstPosition = false;

  double _currentForwardG = 0.0;
  double _currentLateralG = 0.0;
  bool _isForwardCalibrated = false;
  // Startup calibration progress from OrientationCalibrationService. Showing
  // 0/2 vs 1/2 makes it obvious whether no candidate has qualified yet or the
  // service is waiting for one more consistent interval.
  int _forwardCalibrationConfirmations = 0;
  int _forwardCalibrationConfirmationsRequired = 2;

  // Formats g-force with a leading sign, avoiding "-0.0"
  String _formatGForce(double gForce) {
    String formatted = gForce.toStringAsFixed(1);
    if (formatted == '-0.0') {
      formatted = '0.0';
    }
    if (formatted.startsWith('-')) {
      return formatted;
    }
    return '+$formatted';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed = DateTime.now().difference(_tripStartTime));
    });
    _startListening();
    _startAccelerometer();
    _startUserAccelerometer();
    _startGyroscope();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _focusedDrivingGrading.handleLifecycleStateChange(state, DateTime.now());
    // Coming back to "resumed" may have just closed out a violation and
    // changed the grade, so refresh the displayed numbers.
    if (mounted) setState(() {});
  }

  void _startAccelerometer() {
    // Raw acceleration is used ONLY to maintain the gravity/up direction.
    // Live driving G comes from the separate gravity-removed stream below.
    _accelerometerSubscription = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_orientationCalibration.addAccelerometerSample);
  }

  void _startUserAccelerometer() {
    // Authoritative gravity-removed vehicle acceleration. Android keeps these
    // sensor axes fixed to the physical device's natural coordinate system so
    // they are unaffected by the app's portrait/landscape UI rotation.
    _userAccelerometerSubscription = userAccelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_handleUserAccelerometerEvent);
  }

  void _startGyroscope() {
    // Feeds OrientationCalibrationService's lateral (turning) G estimate.
    _gyroscopeSubscription = gyroscopeEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_orientationCalibration.addGyroscopeSample);
  }

  // Smoothness grading needs forward (braking/accelerating) and lateral
  // (turning) G-force, derived from OrientationCalibrationService:
  //  - Raw accelerometer + gyro estimate which way is UP, defining the
  //    vehicle's horizontal plane.
  //  - Live/calibration vehicle acceleration comes from the platform's
  //    automatically gravity-removed UserAccelerometerEvent.
  //  - Before forward-axis calibration, gyro yaw rate provides a temporary
  //    lateral estimate and turn gate. After calibration, forward/lateral G
  //    are direct projections of that gravity-removed acceleration vector.
  //  - GPS speed trend is used only to label clean buffered calibration
  //    intervals. Once calibrated, live magnitude and sign come from sensor
  //    data at full rate.
  // See orientation_calibration_service.dart for the full explanation.
  void _handleUserAccelerometerEvent(UserAccelerometerEvent event) {
    // Always feed the orientation service, even before the first usable GPS
    // fix. GPS is needed only to label calibration intervals, not to obtain
    // the gravity-removed linear acceleration itself.
    _orientationCalibration.addUserAccelerometerSample(event);

    final position = _lastPosition;
    // Wait for a GPS fix so violations can be tagged with coordinates
    if (position == null) return;

    // Only grade smoothness while the vehicle is actually moving, so
    // handling noise (picking the phone up, bumping the mount at a red
    // light) doesn't get counted as harsh braking/accelerating/turning.
    final isMoving = _currentSpeedMph >= _minSpeedMph;
    final isForwardCalibrated = _orientationCalibration.isForwardCalibrated;
    final forwardCalibrationConfirmations =
        _orientationCalibration.forwardCalibrationConfirmations;
    final forwardCalibrationConfirmationsRequired =
        _orientationCalibration.forwardCalibrationConfirmationsRequired;
    // Before calibration, forwardG == 0 is only a placeholder. Keep sending
    // zero into the existing grader (which is neutral), but preserve the
    // calibration state separately so the UI never presents it as measured G.
    final forwardG = isMoving && isForwardCalibrated
        ? _orientationCalibration.forwardG
        : 0.0;
    final lateralG = isMoving ? _orientationCalibration.lateralG : 0.0;

    _smoothnessGrading.addSample(
      forwardG: forwardG,
      lateralG: lateralG,
      latitude: position.latitude,
      longitude: position.longitude,
      timestamp: event.timestamp,
    );

    if (mounted) {
      setState(() {
        _currentForwardG = forwardG;
        _currentLateralG = lateralG;
        _isForwardCalibrated = isForwardCalibrated;
        _forwardCalibrationConfirmations = forwardCalibrationConfirmations;
        _forwardCalibrationConfirmationsRequired =
            forwardCalibrationConfirmationsRequired;
      });
    }
  }

  Future<void> _startListening() async {
    // Bump GPS to its faster trip-active interval
    await BackgroundLocationService.enterTripMode();

    if (!BackgroundLocationService.isTracking) {
      await BackgroundLocationService.start();
    }
    _positionSubscription = BackgroundLocationService.positionStream.listen(
      _handlePosition,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _elapsedTimer?.cancel();
    _positionSubscription?.cancel();
    _accelerometerSubscription?.cancel();
    _userAccelerometerSubscription?.cancel();
    _gyroscopeSubscription?.cancel();
    // Drop back to the idle GPS interval now that the trip is over
    BackgroundLocationService.exitTripMode();
    super.dispose();
  }

  void _handlePosition(Position position) {
    // Cache fix
    if (!_receivedFirstPosition) {
      _receivedFirstPosition = true;
      _lastPosition = position;
      return;
    }

    // Skip updates GPS flags as unreliable
    if (position.accuracy > _maxTrustedHorizontalAccuracyMeters) {
      return;
    }

    final previous = _lastPosition;
    if (previous == null) return;

    final rawSpeedMph = _resolveSpeedMph(position, previous);
    double speedMph = rawSpeedMph;
    if (rawSpeedMph < _minSpeedMph) {
      speedMph = 0.0;
    }

    // Ground truth for orientation calibration: GPS speed trend labels the
    // buffered accelerometer samples from the interval that just ended so
    // the service can learn/refine the fixed vehicle-forward axis. GPS
    // heading change is also compared against the gyroscope's integrated
    // turning to slowly correct yaw-rate bias (see addGpsSample).
    //
    // A reported heading accuracy of 0 degrees is valid, so
    // only negative or non-finite values are treated as unavailable.
    final headingDegrees = position.heading.isFinite && position.heading >= 0
        ? position.heading
        : null;
    final headingAccuracyDegrees =
        position.headingAccuracy.isFinite && position.headingAccuracy >= 0
        ? position.headingAccuracy
        : null;

    _orientationCalibration.addGpsSample(
      speedMps: rawSpeedMph / _metersPerSecondToMph,
      headingDegrees: headingDegrees,
      timestamp: position.timestamp,
      headingAccuracyDegrees: headingAccuracyDegrees,
    );

    double addedMiles = 0;
    if (speedMph >= _minSpeedForDistanceMph) {
      final meters = Geolocator.distanceBetween(
        previous.latitude,
        previous.longitude,
        position.latitude,
        position.longitude,
      );
      addedMiles = meters * _metersToMiles;
    }

    // Snap to 0 immediately when stopped, otherwise smooth with alpha
    if (speedMph == 0) {
      _smoothedSpeedMph = 0;
    } else {
      _smoothedSpeedMph = (_speedSmoothingAlpha * speedMph) +
          ((1 - _speedSmoothingAlpha) * _smoothedSpeedMph);
    }

    _properSpeedGrading.addSample(
      speedMph: _smoothedSpeedMph,
      speedLimitMph: _postedSpeedLimitMph,
      timestamp: position.timestamp,
      latitude: position.latitude,
      longitude: position.longitude,
    );

    // Keep this fresh regardless of "mounted" below, so a background period
    // that started (or that's about to start) always has an up-to-date
    // speed/location to attribute to it, even while the app isn't visible.
    _focusedDrivingGrading.updateLiveState(
      speedMph: _smoothedSpeedMph,
      latitude: position.latitude,
      longitude: position.longitude,
    );

    if (!mounted) return;
    setState(() {
      _currentSpeedMph = _smoothedSpeedMph;
      _milesDriven += addedMiles;
      _lastPosition = position;
    });

    _maybeRefreshSpeedLimit(position);
  }

  // Uses platform-reported speed only when trusted and it agrees with the
  // manually calculated speed. Otherwise falls back to manual calculation.
  double _resolveSpeedMph(Position position, Position previous) {
    final dtSeconds =
        position.timestamp.difference(previous.timestamp).inMilliseconds /
        1000.0;

    double calculatedSpeedMph = 0.0;
    if (dtSeconds > 0) {
      final meters = Geolocator.distanceBetween(
        previous.latitude,
        previous.longitude,
        position.latitude,
        position.longitude,
      );
      calculatedSpeedMph = (meters / dtSeconds) * _metersPerSecondToMph;
    }

    final reportedSpeedMph = position.speed * _metersPerSecondToMph;
    final speedAccuracyTrusted =
        !position.isMocked &&
        position.speed >= 0 &&
        position.speedAccuracy > 0 &&
        position.speedAccuracy <= _maxTrustedSpeedAccuracyMps;
    final speedsAgree =
        (reportedSpeedMph - calculatedSpeedMph).abs() <=
        _maxSpeedDisagreementMph;

    if (speedAccuracyTrusted && speedsAgree) {
      return reportedSpeedMph;
    }
    return calculatedSpeedMph;
  }

  Future<void> _maybeRefreshSpeedLimit(Position position) async {
    final now = DateTime.now();
    final dueForRefresh =
        _lastSpeedLimitFetchTime == null ||
        now.difference(_lastSpeedLimitFetchTime!) >= _speedLimitRefreshInterval;

    if (_isFetchingSpeedLimit || !dueForRefresh) return;

    // Set before the await so a second update can't slip past the guard
    _isFetchingSpeedLimit = true;
    _lastSpeedLimitFetchTime = now;

    try {
      final token = await AuthStorage.readToken();
      if (token == null) {
        debugPrint('SPEED LIMIT FETCH SKIPPED: no auth token');
        return;
      }

      final limit = await SpeedLimitService.fetchPostedSpeedLimitMph(
        latitude: position.latitude,
        longitude: position.longitude,
        token: token,
      );

      if (!mounted) return;
      setState(() => _postedSpeedLimitMph = limit);
    } catch (e) {
      debugPrint('SPEED LIMIT FETCH ERROR: $e');
    } finally {
      _isFetchingSpeedLimit = false;
    }
  }

  void _stopTrip() {
    final now = DateTime.now();
    // Close out any in-progress streak so it's counted below
    _properSpeedGrading.finalizeTrip();
    _smoothnessGrading.finalizeTrip();
    _focusedDrivingGrading.finalizeTrip();

    final summary = TripSummary(
      startTime: _tripStartTime,
      endTime: now,
      elapsed: now.difference(_tripStartTime),
      milesDriven: _milesDriven,
      overallGrade: _overallGrade,
      properSpeedGrade: _properSpeedGrading.grade,
      speedingViolations: _properSpeedGrading.violations,
      brakingGrade: _smoothnessGrading.brakingGrade,
      acceleratingGrade: _smoothnessGrading.acceleratingGrade,
      turningGrade: _smoothnessGrading.turningGrade,
      brakingViolations: _smoothnessGrading.violationsFor(
        SmoothnessCategory.braking,
      ),
      acceleratingViolations: _smoothnessGrading.violationsFor(
        SmoothnessCategory.accelerating,
      ),
      turningViolations: _smoothnessGrading.violationsFor(
        SmoothnessCategory.turning,
      ),
      focusedDrivingGrade: _focusedDrivingGrading.grade,
      focusedDrivingViolations: _focusedDrivingGrading.violations,
    );

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => DrivingReportScreen(summary: summary)),
    );
  }

  double? get _speedDifference {
    final limit = _postedSpeedLimitMph;
    if (limit == null) {
      return null;
    }
    return _currentSpeedMph - limit;
  }

  bool get _isSpeeding =>
      (_speedDifference ?? double.negativeInfinity) >= _speedingThresholdMph;

  bool get _isCloseToSpeeding {
    final difference = _speedDifference;
    return difference != null &&
        difference > 0 &&
        difference < _speedingThresholdMph;
  }

  String get _speedingCountLabel {
    final count = _properSpeedGrading.violationCount;
    return count == 1 ? '1 time speeding' : '$count times speeding';
  }

  String get _focusedDrivingCountLabel {
    final count = _focusedDrivingGrading.violationCount;
    return count == 1 ? '1 time off app' : '$count times off app';
  }

  // Overall Grade is the average of every currently graded category
  double get _overallGrade {
    final grades = [
      _properSpeedGrading.grade,
      _smoothnessGrading.brakingGrade,
      _smoothnessGrading.acceleratingGrade,
      _smoothnessGrading.turningGrade,
      _focusedDrivingGrading.grade,
    ];
    return grades.reduce((a, b) => a + b) / grades.length;
  }

  @override
  Widget build(BuildContext context) {
    final overallGrade = _overallGrade;

    Color? speedColor;
    if (_isSpeeding) {
      speedColor = Colors.red;
    } else if (_isCloseToSpeeding) {
      speedColor = Colors.orange;
    }

    String speedLimitText = '—';
    if (_postedSpeedLimitMph != null) {
      speedLimitText = '${_postedSpeedLimitMph!.toStringAsFixed(0)} MPH';
    }

    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Live Dashboard'),
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Stats scroll on short screens; Stop Trip stays pinned below
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildGradeCard(context, 'Overall Grade', overallGrade),
                        const SizedBox(height: 12),
                        _buildGradeCard(
                          context,
                          'Proper Speed',
                          _properSpeedGrading.grade,
                          subtitle: _speedingCountLabel,
                        ),
                        const SizedBox(height: 12),
                        _buildGradeCard(
                          context,
                          'Focused Driving',
                          _focusedDrivingGrading.grade,
                          subtitle: _focusedDrivingCountLabel,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _buildSmoothnessGradeTile(
                                context,
                                SmoothnessCategory.braking,
                              ),
                            ),
                            const SizedBox(width: 1),
                            Expanded(
                              child: _buildSmoothnessGradeTile(
                                context,
                                SmoothnessCategory.accelerating,
                              ),
                            ),
                            const SizedBox(width: 1),
                            Expanded(
                              child: _buildSmoothnessGradeTile(
                                context,
                                SmoothnessCategory.turning,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: _buildStat(
                                context,
                                'Time Elapsed',
                                formatElapsed(_elapsed),
                              ),
                            ),
                            Expanded(
                              child: _buildStat(
                                context,
                                'Miles Driven',
                                _milesDriven.toStringAsFixed(1),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _buildStat(
                                context,
                                'Current Speed',
                                '${_currentSpeedMph.toStringAsFixed(0)} MPH',
                                valueColor: speedColor,
                              ),
                            ),
                            Expanded(
                              child: _buildStat(
                                context,
                                'Speed Limit',
                                speedLimitText,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _buildStat(
                                context,
                                'Forward G',
                                _isForwardCalibrated
                                    ? _formatGForce(_currentForwardG)
                                    : 'CAL $_forwardCalibrationConfirmations/'
                                          '$_forwardCalibrationConfirmationsRequired',
                              ),
                            ),
                            Expanded(
                              child: _buildStat(
                                context,
                                'Lateral G',
                                _formatGForce(_currentLateralG),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _stopTrip,
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop Trip'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // "subtitle" is optional so this still works for cards like Overall Grade
  // that don't have a per-category count to show underneath the label.
  Widget _buildGradeCard(
    BuildContext context,
    String label,
    double grade, {
    String? subtitle,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            subtitle == null
                ? Text(label, style: Theme.of(context).textTheme.titleMedium)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
            Text(
              grade.toStringAsFixed(0),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: gradeColor(grade),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmoothnessGradeTile(
    BuildContext context,
    SmoothnessCategory category,
  ) {
    final grade = _smoothnessGrading.gradeFor(category);
    final violationCount = _smoothnessGrading.violationCountFor(category);

    String eventsText = '$violationCount events';
    if (violationCount == 1) {
      eventsText = '1 event';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        child: Column(
          children: [
            Text(
              category.label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              grade.toStringAsFixed(0),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: gradeColor(grade),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(eventsText, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildStat(
    BuildContext context,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Column(
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: valueColor,
            // Keeps numbers the same width so they don't shift around
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}