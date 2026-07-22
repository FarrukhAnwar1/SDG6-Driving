// Shown while a trip is in progress. Tracks elapsed time, distance driven,
// current speed, the posted speed limit, and live driving grades.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../widgets/background_location_service.dart';
import '../widgets/speed_grading_service.dart';
import '../widgets/speed_limit_service.dart';
import '../widgets/trip_summary.dart';
import '../widgets/auth_storage.dart';

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

  StreamSubscription<Position>? _positionSubscription;
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

  @override
  void initState() {
    super.initState();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed = DateTime.now().difference(_tripStartTime));
    });
    _startListening();
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
    // TODO: Overall grade should be weighted average of all grades
    // For now, we just use the proper speed grade as a placeholder for overall grade
    final summary = TripSummary(
      startTime: _tripStartTime,
      endTime: now,
      elapsed: now.difference(_tripStartTime),
      milesDriven: _milesDriven,
      overallGrade: _properSpeedGrading.grade,
      properSpeedGrade: _properSpeedGrading.grade,
      speedingOffenseCount: _properSpeedGrading.speedingOffenseCount,
      totalSpeedingDuration: _properSpeedGrading.totalSpeedingDuration,
    );

    // TODO: Navigate to the Driving Report screen (passing the summary)
    Navigator.of(context).pop(summary);
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

  @override
  Widget build(BuildContext context) {
    final overallGrade = _properSpeedGrading.grade;

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
