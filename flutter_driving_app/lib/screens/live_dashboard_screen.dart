// Shown while a trip is in progress. Tracks elapsed time, distance driven,
// current speed, the road's speed limit, and live driving grades.
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

  // How often to refresh the road's speed limit and grading tolerance
  static const Duration _speedLimitRefreshInterval = Duration(seconds: 4);

  // Backend thresholds include this buffer when inferring the speed limit range.
  // Subtract it only for display; grading uses the full backend threshold.
  static const double _speedingBufferMph = 5;

  // Below this speed, ignore distance/movement to avoid GPS jitter
  static const double _minSpeedForDistanceMph = 3.0;
  static const double _minSpeedMph = 3.0;

  // Ignore speed updates with worse accuracy than this
  static const double _maxTrustedSpeedAccuracyMps = 1.5;
  static const double _maxSpeedDisagreementMph = 10.0;
  static const double _maxTrustedHorizontalAccuracyMeters = 25.0;

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
  SpeedLimit? _speedLimit;

  Position? _lastPosition;
  DateTime? _lastSpeedLimitFetchTime;
  bool _isFetchingSpeedLimit = false;

  bool _receivedFirstPosition = false;

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
    // Before calibration, forwardG == 0 is only a placeholder. Keep sending
    // zero into the existing grader (which is neutral).
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
      _smoothedSpeedMph =
          (_speedSmoothingAlpha * speedMph) +
          ((1 - _speedSmoothingAlpha) * _smoothedSpeedMph);
    }

    _properSpeedGrading.addSample(
      speedMph: _smoothedSpeedMph,
      speedLimitMph: _speedLimit?.canGrade == true
          ? _speedLimit!.speedLimitMph
          : null,
      speedingThresholdMph: _speedLimit?.speedingThresholdMph,
      roadName: _speedLimit?.roadName,
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
    // Use the same GPS timeline as the grader to schedule road refreshes
    final now = position.timestamp;
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
        if (mounted) setState(() => _speedLimit = null);
        return;
      }

      final limit = await SpeedLimitService.fetchSpeedLimit(
        latitude: position.latitude,
        longitude: position.longitude,
        token: token,
      );

      if (!mounted) return;
      setState(() => _speedLimit = limit);
    } catch (e) {
      debugPrint('SPEED LIMIT FETCH ERROR: $e');
      if (mounted) setState(() => _speedLimit = null);
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
    final limit = _speedLimit;
    if (limit == null || !limit.canGrade) {
      return null;
    }
    return _currentSpeedMph - limit.speedLimitMph!;
  }

  // Share the inferred speed limit range with the warning colors
  // so they are shown accordingly (only red when speed is above
  // inferred limit + threshold).
  double get _estimatedRangeMph {
    final limit = _speedLimit;
    if (limit == null ||
        !limit.canGrade ||
        limit.source != SpeedLimitSource.inferred) {
      return 0;
    }
    final range = limit.speedingThresholdMph! - _speedingBufferMph;
    return range > 0 ? range : 0;
  }

  bool get _isSpeeding {
    final difference = _speedDifference;
    return difference != null &&
        difference >= _speedLimit!.speedingThresholdMph!;
  }

  bool get _isCloseToSpeeding {
    final difference = _speedDifference;
    return difference != null &&
        difference > _estimatedRangeMph &&
        difference < _speedLimit!.speedingThresholdMph!;
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

    final hasSpeedLimit = _speedLimit?.canGrade == true;
    final isInferred = _speedLimit?.source == SpeedLimitSource.inferred;
    final estimatedRangeMph = _estimatedRangeMph;
    final estimatedRangeText = estimatedRangeMph > 0
        ? '±${estimatedRangeMph == estimatedRangeMph.roundToDouble() ? estimatedRangeMph.toStringAsFixed(0) : estimatedRangeMph.toString()}'
        : '';
    final speedLimitText = hasSpeedLimit
        ? _speedLimit!.speedLimitMph!.toStringAsFixed(0)
        : '--';
    final roadName = _speedLimit?.roadName;

    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Live Dashboard'),
          centerTitle: true,
          automaticallyImplyLeading: false,
          scrolledUnderElevation: 0,
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Allocate the available height so every grade stays visible
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final gap = constraints.maxHeight < 560 ? 10.0 : 16.0;
                      final contentHeight = constraints.maxHeight - gap * 2;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: contentHeight * 0.28,
                            child: _buildSpeedHero(
                              context,
                              speedColor: speedColor,
                              limitLabel: isInferred
                                  ? 'EST.\nLIMIT'
                                  : 'SPEED\nLIMIT',
                              limitValue: speedLimitText,
                              limitRange: estimatedRangeText,
                              roadName: roadName,
                            ),
                          ),
                          SizedBox(height: gap),
                          SizedBox(
                            height: contentHeight * 0.22,
                            child: _buildTripCard(context, overallGrade),
                          ),
                          SizedBox(height: gap),
                          Expanded(
                            child: _buildGradesCard(context, hasSpeedLimit),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('stop-trip'),
                  onPressed: _stopTrip,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(60),
                    textStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  icon: const Icon(Icons.stop_circle_outlined, size: 28),
                  label: const Text('Stop Trip'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Rounded, softly outlined container shared by the different dashboard sections
  Widget _buildSurface(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(20),
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(padding: padding, child: child),
    );
  }

  // Big current speed on the left, speed limit sign on the right, road name
  // underneath. Meant to be read at a glance.
  Widget _buildSpeedHero(
    BuildContext context, {
    required Color? speedColor,
    required String limitLabel,
    required String limitValue,
    required String limitRange,
    required String? roadName,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final subtleColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final hasRoad = roadName != null && roadName.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _currentSpeedMph.toStringAsFixed(0),
                          key: const ValueKey('current-speed'),
                          style: textTheme.displayLarge?.copyWith(
                            fontSize: 112,
                            fontWeight: FontWeight.w800,
                            height: 1.0,
                            color: speedColor,
                            // Keeps numbers the same width so they don't shift
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 24,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'MPH',
                          style: textTheme.titleMedium?.copyWith(
                            letterSpacing: 3,
                            fontWeight: FontWeight.w600,
                            color: subtleColor,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: _buildSpeedLimitSign(
                  context,
                  label: limitLabel,
                  value: limitValue,
                  rangeText: limitRange,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Fixed height so the layout doesn't jump when the road name changes
        SizedBox(
          height:
              24.0 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.5),
          child: hasRoad
              ? Row(
                  children: [
                    Icon(
                      Icons.location_on_outlined,
                      size: 20,
                      color: subtleColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        roadName.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyLarge?.copyWith(
                          fontSize: 18,
                          height: 1.2,
                          color: subtleColor,
                        ),
                      ),
                    ),
                  ],
                )
              : null,
        ),
      ],
    );
  }

  // Outlined road-sign style badge
  Widget _buildSpeedLimitSign(
    BuildContext context, {
    required String label,
    required String value,
    required String rangeText,
  }) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Container(
      width: 96,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ink, width: 3),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            key: const ValueKey('speed-limit-label'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: ink,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              height: 1.1,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              key: const ValueKey('speed-limit-value'),
              maxLines: 1,
              style: TextStyle(
                color: ink,
                fontSize: 44,
                fontWeight: FontWeight.w800,
                height: 1.05,
              ),
            ),
          ),
          if (rangeText.isNotEmpty)
            Text(
              rangeText,
              key: const ValueKey('speed-limit-range'),
              style: TextStyle(
                color: ink,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }

  // Overall grade ring alongside elapsed time and miles
  Widget _buildTripCard(BuildContext context, double overallGrade) {
    return _buildSurface(
      context,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final ringSize = constraints.maxHeight
              .clamp(0.0, (constraints.maxWidth * 0.45).clamp(0.0, 120.0))
              .toDouble();
          return Row(
            children: [
              _buildOverallGradeRing(context, overallGrade, ringSize),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _buildStat(
                        context,
                        'TIME',
                        formatElapsed(_elapsed),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _buildStat(
                        context,
                        'MILES',
                        _milesDriven.toStringAsFixed(1),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildOverallGradeRing(
    BuildContext context,
    double grade,
    double size,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final color = gradeColor(grade);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: (grade / 100).clamp(0.0, 1.0).toDouble(),
              strokeWidth: size / 12,
              strokeCap: StrokeCap.round,
              color: color,
              backgroundColor: scheme.outlineVariant,
            ),
          ),
          Padding(
            padding: EdgeInsets.all(size * 0.15),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    grade.toStringAsFixed(0),
                    style: textTheme.displaySmall?.copyWith(
                      fontSize: 42,
                      fontWeight: FontWeight.w800,
                      height: 1.0,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'OVERALL',
                    style: textTheme.labelMedium?.copyWith(
                      letterSpacing: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStat(BuildContext context, String label, String value) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              label,
              key: ValueKey('stat-$label-label'),
              textAlign: TextAlign.right,
              style: textTheme.labelLarge?.copyWith(
                letterSpacing: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          flex: 2,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              value,
              key: ValueKey('stat-$label-value'),
              textAlign: TextAlign.right,
              style: textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                // Keeps numbers the same width so they don't shift around
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // One card holding every category grade as a row with a progress bar
  Widget _buildGradesCard(BuildContext context, bool hasSpeedLimit) {
    return _buildSurface(
      context,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Column(
        children: [
          Expanded(
            child: _buildGradeRow(
              context,
              'Proper Speed',
              _properSpeedGrading.grade
            ),
          ),
          Expanded(
            child: _buildGradeRow(
              context,
              'Focused Driving',
              _focusedDrivingGrading.grade,
            ),
          ),
          for (final category in [
            SmoothnessCategory.braking,
            SmoothnessCategory.accelerating,
            SmoothnessCategory.turning,
          ]) ...[
            Expanded(
              child: _buildGradeRow(
                context,
                category.label,
                _smoothnessGrading.gradeFor(category),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGradeRow(
    BuildContext context,
    String label,
    double grade, {
    String? note,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final color = gradeColor(grade);

    return Padding(
      key: ValueKey('grade-$label'),
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: textTheme.titleMedium?.copyWith(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (note != null)
                          Text(
                            note,
                            style: textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    grade.toStringAsFixed(0),
                    style: textTheme.headlineMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (grade / 100).clamp(0.0, 1.0).toDouble(),
              minHeight: 6,
              color: color,
              backgroundColor: scheme.outlineVariant,
            ),
          ),
        ],
      ),
    );
  }
}
