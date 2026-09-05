// Shown while a trip is in progress. Tracks elapsed time, distance driven,
// current speed, the posted speed limit, and live driving grades.
// Also sets up and calls live grading services, and passes completed
// trip information to the Driving Report screen.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../widgets/background_location_service.dart';
import '../widgets/speed_grading_service.dart';
import '../widgets/speed_limit_service.dart';
import '../widgets/smoothness_grading_service.dart';
import '../widgets/trip_summary.dart';
import '../widgets/auth_storage.dart';
import 'driving_report_screen.dart';

String formatElapsed(Duration d) {
  String twoDigits(int n) => n.toString().padLeft(2, '0');
  final hours = twoDigits(d.inHours);
  final minutes = twoDigits(d.inMinutes.remainder(60));
  final seconds = twoDigits(d.inSeconds.remainder(60));
  return d.inHours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

class LiveDashboardScreen extends StatefulWidget {
  const LiveDashboardScreen({super.key});

  @override
  State<LiveDashboardScreen> createState() => _LiveDashboardScreenState();
}

class _LiveDashboardScreenState extends State<LiveDashboardScreen> {
  static const double _metersToMiles = 0.000621371;
  static const double _metersPerSecondToMph = 2.23694;
  static const double _gravityMetersPerSecondSquared = 9.80665;

  // Controls how often speed limit is fetched
  static const Duration _speedLimitRefreshInterval = Duration(seconds: 4);

  // Below this speed, we don't count distance driven to avoid GPS jitter
  static const double _minSpeedForDistanceMph = 3.0;

  // Below this speed, we considered the vehicle stopped to avoid GPS jitter
  static const double _minSpeedMph = 3.0;

  // Ignore speed updates with a speedAccuracy worse than this
  static const double _maxTrustedSpeedAccuracyMps = 1.5; // about 3.4 mph

  // Ignore reported speed updates that disagree with the
  // manually calculated speed by more than this
  static const double _maxSpeedDisagreementMph = 10.0;

  // Ignore speed updates with a horizontal accuracy worse than this
  static const double _maxTrustedHorizontalAccuracyMeters = 25.0;

  // Current speed is flagged red once it exceeds the posted limit by this much
  static const double _speedingThresholdMph = 5.0;

  // Exponential moving average factor applied to the resolved speed, to cut
  // frame-to-frame jitter the way a real speed display does.
  // Lower = smoother but laggier/more inaccurate, higher = more jittery but more responsive/accurate.
  // 0 = Never update so output stays at the previous smoothed value forever.
  // 1 = Never smooth so output equals the current measurement every update.
  static const double _speedSmoothingAlpha = 1;

  final DateTime _tripStartTime = DateTime.now();
  final SpeedGradingService _properSpeedGrading = SpeedGradingService();
  final SmoothnessGradingService _smoothnessGrading =
      SmoothnessGradingService();

  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<UserAccelerometerEvent>? _accelerometerSubscription;
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

  @override
  void initState() {
    super.initState();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed = DateTime.now().difference(_tripStartTime));
    });
    _startListening();
    _startAccelerometer();
  }

  void _startAccelerometer() {
    _accelerometerSubscription = userAccelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_handleAccelerometerEvent);
  }

  // This smoothness grading assumes the phone is mounted upright (portrait), standing
  // roughly vertical (the typical vent-clip or windshield/dash-suction mount),
  // not laid flat on the dash, with the back of the phone facing the
  // front of the car and the screen facing back toward the driver.
  //
  // Under that mounting condition: the device's Z axis (straight out of the screen,
  // toward the driver) lines up with the vehicle's forward/backward axis,
  // and the screen points backward, so the back of the phone points forward,
  // meaning "accelerating forward" reads as negative Z and "braking" reads
  // as positive Z. The device's Y axis (top-to-bottom of the screen) ends
  // up roughly vertical in this mount rather than forward/backward. The
  // device's X axis (left-to-right of the screen) lines up with the
  // vehicle's left/right axis regardless of how upright vs. reclined the
  // mount is, as long as it's portrait and not rolled sideways.
  //
  // A mount that reclines the phone back significantly (propped flatish
  // against the dash/windshield rather than held near-vertical) would shift
  // the forward signal from Z toward Y, so this reading degrades the more
  // the mount leans away from vertical. A phone mounted some other way
  // entirely (landscape, upside down, flat in a cupholder) will read
  // rotated values here and throw off which category a hard event gets
  // counted under. A more robust version would derive the rotation from
  // the device's fused orientation, or from the offset between the
  // device's compass heading and the GPS course, instead of assuming a
  // fixed mount.
  void _handleAccelerometerEvent(UserAccelerometerEvent event) {
    final position = _lastPosition;
    // Wait for a GPS fix before grading so violations can be tagged with
    // real coordinates.
    if (position == null) return;

    // Only grade smoothness while the vehicle is actually moving, so
    // handling noise (picking the phone up, bumping the mount at a red
    // light) doesn't get counted as harsh braking/accelerating/turning.
    final isMoving = _currentSpeedMph >= _minSpeedMph;
    final forwardG = isMoving ? -event.z / _gravityMetersPerSecondSquared : 0.0;
    final lateralG = isMoving ? event.x / _gravityMetersPerSecondSquared : 0.0;

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
      });
    }
  }

  Future<void> _startListening() async {
    // Bump the underlying GPS stream to its 1-second trip-active interval
    await BackgroundLocationService.enterTripMode();

    // Restart tracking just in case
    if (!BackgroundLocationService.isTracking) {
      await BackgroundLocationService.start();
    }
    _positionSubscription = BackgroundLocationService.positionStream.listen(
      _handlePosition,
    );
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _positionSubscription?.cancel();
    _accelerometerSubscription?.cancel();
    // Drop back to the longer idle GPS interval now that the trip is over
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

    // Skip updates GPS itself flags as unreliable
    if (position.accuracy > _maxTrustedHorizontalAccuracyMeters) {
      return;
    }

    final previous = _lastPosition;
    if (previous == null) return;

    final rawSpeedMph = _resolveSpeedMph(position, previous);
    final speedMph = rawSpeedMph < _minSpeedMph ? 0.0 : rawSpeedMph;

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

    // Snap straight to 0 instead of decaying, so coming to a stop reads
    // immediately rather than trailing off. Otherwise, smooth with alpha.
    _smoothedSpeedMph = speedMph == 0
        ? 0
        : (_speedSmoothingAlpha * speedMph) +
              ((1 - _speedSmoothingAlpha) * _smoothedSpeedMph);

    _properSpeedGrading.addSample(
      speedMph: _smoothedSpeedMph,
      speedLimitMph: _postedSpeedLimitMph,
      timestamp: position.timestamp,
    );

    if (!mounted) return;
    setState(() {
      _currentSpeedMph = _smoothedSpeedMph;
      _milesDriven += addedMiles;
      _lastPosition = position;
    });

    _maybeRefreshSpeedLimit(position);
  }

  // Prefers the platform-reported speed, but only when it's flagged
  // as confident, so high speedAccuracy, not from a mock provider, AND corroborated
  // by manual speed calculation. Otherwise, returns manual speed calculation based on
  // displacement and time between updates.
  double _resolveSpeedMph(Position position, Position previous) {
    final dtSeconds =
        position.timestamp.difference(previous.timestamp).inMilliseconds /
        1000.0;
    final calculatedSpeedMph = dtSeconds > 0
        ? (Geolocator.distanceBetween(
                    previous.latitude,
                    previous.longitude,
                    position.latitude,
                    position.longitude,
                  ) /
                  dtSeconds) *
              _metersPerSecondToMph
        : 0.0;

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

    // Set these before the await below so a second position update landing
    // while we're still reading the token doesn't slip past the guard above
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
    // Close out a streak still in progress (driver was speeding right up
    // until Stop Trip was pressed) so it's counted below.
    _properSpeedGrading.finalizeTrip();
    _smoothnessGrading.finalizeTrip();

    final summary = TripSummary(
      startTime: _tripStartTime,
      endTime: now,
      elapsed: now.difference(_tripStartTime),
      milesDriven: _milesDriven,
      overallGrade: _overallGrade,
      properSpeedGrade: _properSpeedGrading.grade,
      speedingOffenseCount: _properSpeedGrading.speedingOffenseCount,
      totalSpeedingDuration: _properSpeedGrading.totalSpeedingDuration,
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
    );

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => DrivingReportScreen(summary: summary)),
    );
  }

  double? get _speedDifference {
    final limit = _postedSpeedLimitMph;
    return limit == null ? null : _currentSpeedMph - limit;
  }

  bool get _isSpeeding =>
      (_speedDifference ?? double.negativeInfinity) >= _speedingThresholdMph;

  bool get _isCloseToSpeeding {
    final difference = _speedDifference;
    return difference != null &&
        difference > 0 &&
        difference < _speedingThresholdMph;
  }

  // Overall Grade is the average of every currently graded category
  double get _overallGrade {
    final grades = [
      _properSpeedGrading.grade,
      _smoothnessGrading.brakingGrade,
      _smoothnessGrading.acceleratingGrade,
      _smoothnessGrading.turningGrade,
    ];
    return grades.reduce((a, b) => a + b) / grades.length;
  }

  @override
  Widget build(BuildContext context) {
    final overallGrade = _overallGrade;

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
                _buildGradeCard(context, 'Overall Grade', overallGrade),
                const SizedBox(height: 12),
                _buildGradeCard(
                  context,
                  'Proper Speed',
                  _properSpeedGrading.grade,
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
                        valueColor: _isSpeeding
                            ? Colors.red
                            : _isCloseToSpeeding
                            ? Colors.orange
                            : null,
                      ),
                    ),
                    Expanded(
                      child: _buildStat(
                        context,
                        'Speed Limit',
                        _postedSpeedLimitMph == null
                            ? '—'
                            : '${_postedSpeedLimitMph!.toStringAsFixed(0)} MPH',
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
                        _currentForwardG.toStringAsFixed(1),
                      ),
                    ),
                    Expanded(
                      child: _buildStat(
                        context,
                        'Lateral G',
                        _currentLateralG.toStringAsFixed(1),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
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

  Widget _buildGradeCard(BuildContext context, String label, double grade) {
    final color = grade >= 90
        ? Colors.green
        : grade >= 70
        ? Colors.orange
        : Colors.red;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleMedium),
            Text(
              grade.toStringAsFixed(0),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: color,
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
    final color = grade >= 90
        ? Colors.green
        : grade >= 70
        ? Colors.orange
        : Colors.red;

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
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              violationCount == 1 ? '1 event' : '$violationCount events',
              style: Theme.of(context).textTheme.bodySmall,
            ),
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
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(color: valueColor),
        ),
      ],
    );
  }
}
