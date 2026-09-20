// Post driving report screen displaying results and feedback,
// and sending the report to the backend.
import 'package:flutter/material.dart';
import '../widgets/driving_report_api.dart';
import '../widgets/driving_report_policy.dart';
import '../widgets/grade_utils.dart';
import '../widgets/trip_summary.dart';
import 'home_screen.dart';

class DrivingReportScreen extends StatefulWidget {
  final TripSummary summary;

  const DrivingReportScreen({super.key, required this.summary});

  @override
  State<DrivingReportScreen> createState() => _DrivingReportScreenState();
}

class _DrivingReportScreenState extends State<DrivingReportScreen> {
  bool _isSending = false;
  bool _sentSuccessfully = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _sendReport();
  }

  Future<void> _sendReport() async {
    final summary = widget.summary;
    if (!canGenerateDrivingReport(summary.milesDriven) ||
        _isSending ||
        _sentSuccessfully) {
      return;
    }

    setState(() {
      _isSending = true;
      _errorMessage = null;
    });

    final result = await DrivingReportApi.sendReport(
      startTime: summary.startTime,
      endTime: summary.endTime,
      milesDriven: summary.milesDriven,
      overallGrade: summary.overallGrade,
      properSpeedGrade: summary.properSpeedGrade,
      brakingGrade: summary.brakingGrade,
      acceleratingGrade: summary.acceleratingGrade,
      turningGrade: summary.turningGrade,
      focusedDrivingGrade: summary.focusedDrivingGrade,
    );

    if (!mounted) return;

    setState(() {
      _isSending = false;
      _sentSuccessfully = result.success;
      _errorMessage = result.errorMessage;
    });
  }

  String formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours hr $minutes min';
    }

    return '$minutes min $seconds sec';
  }

  ({String category, double score}) _getLowestScore(TripSummary summary) {
    final scores = {
      'speed': summary.properSpeedGrade,
      'braking': summary.brakingGrade,
      'acceleration': summary.acceleratingGrade,
      'turning': summary.turningGrade,
      'focusedDriving': summary.focusedDrivingGrade,
    };

    final lowest = scores.entries.reduce((a, b) => a.value < b.value ? a : b);

    return (category: lowest.key, score: lowest.value);
  }

  String _getSuggestion(String category, double score) {
    switch (category) {
      case 'speed':
        if (score >= 90) {
          return 'Great job staying within the speed limit!';
        } else if (score >= 80) {
          return 'Nice speed control, make sure to stay consistent.';
        } else if (score >= 70) {
          return 'Looks like you could improve your speed control, try to remember posted speed limits.';
        } else if (score >= 60) {
          return 'Try to reduce how often you go over the posted speed limit.';
        } else {
          return 'Focus on staying within the speed limit, speeding is extremely dangerous!';
        }

      case 'braking':
        return score >= 90
            ? 'Great job braking smoothly! Keep leaving plenty of stopping distance.'
            : 'Leave more space ahead and start braking earlier for smoother stops.';
      case 'acceleration':
        return score >= 90
            ? 'Great job accelerating smoothly! Keep building speed gradually.'
            : 'Press the accelerator gently and build speed gradually.';
      case 'turning':
        return score >= 90
            ? 'Great job taking turns smoothly! Keep slowing down before each turn.'
            : 'Slow down before turns and steer steadily through them.';
      case 'focusedDriving':
        return score >= 90
            ? 'Great focus! Keep your attention on the road and avoid using your phone.'
            : 'Set up your phone before driving and avoid switching apps while moving.';

      default:
        return 'Keep practicing safe driving habits.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;

    return Scaffold(
      appBar: AppBar(title: const Text('Your Driving Report')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: canGenerateDrivingReport(summary.milesDriven)
              ? _buildReport(context, summary)
              : _buildShortTripNotice(context, summary),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: FilledButton(
            onPressed: () {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const HomePage()),
                (route) => false,
              );
            },
            child: const Text('Return Home'),
          ),
        ),
      ),
    );
  }

  Widget _buildShortTripNotice(BuildContext context, TripSummary summary) {
    // Truncate instead of rounding so a trip just under a mile never reads 1.00
    final distance = (summary.milesDriven * 100).floor() / 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.info_outline,
          size: 64,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 24),
        Text(
          'Trip too short for a report',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        const Text(
          'Drive at least 1 mile in a single trip to receive a driving report. '
          'This trip ended before 1 mile, so no report was generated or uploaded.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        _ReportItem(
          icon: Icons.drive_eta,
          title: 'Distance Driven',
          value: '${distance.toStringAsFixed(2)} miles',
        ),
        _ReportItem(
          icon: Icons.access_time_rounded,
          title: 'Trip Duration',
          value: formatDuration(summary.elapsed),
        ),
      ],
    );
  }

  Widget _buildReport(BuildContext context, TripSummary summary) {
    final lowestScore = _getLowestScore(summary);
    final suggestion = _getSuggestion(lowestScore.category, lowestScore.score);

    return Column(
      children: [
        // Send status banner
        if (_isSending) ...[
          const SizedBox(height: 8),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 8),
          const Center(child: Text('Sending report...')),
          const SizedBox(height: 16),
        ] else if (!_sentSuccessfully) ...[
          const SizedBox(height: 8),
          const Center(
            child: Icon(Icons.error_outline, color: Colors.red, size: 40),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _errorMessage ?? 'Failed to send report.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: _sendReport,
              child: const Text('Retry'),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          'Trip Complete!',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 24),

        // Color coded circle with letter grade
        CircleAvatar(
          radius: 65,
          backgroundColor: gradeColorFor(summary.overallGrade),
          child: Text(
            letterGradeFor(summary.overallGrade),
            style: const TextStyle(
              fontSize: 65,
              fontWeight: FontWeight.bold,
              color: Color.fromARGB(255, 0, 0, 0),
            ),
          ),
        ),

        const SizedBox(height: 12),

        Text(
          'Overall Score: ${summary.overallGrade.toStringAsFixed(0)}%',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),

        const SizedBox(height: 32),

        // Display trip summary information
        _ReportItem(
          icon: Icons.speed,
          title: 'Proper Speed Score',
          value: '${summary.properSpeedGrade.toStringAsFixed(0)}%',
        ),

        _ReportItem(
          icon: Icons.multiline_chart,
          title: 'Smoothness Score',
          value: '${summary.smoothnessGrade.toStringAsFixed(0)}%',
          subtitle:
              'Braking: ${summary.brakingGrade.toStringAsFixed(0)}%\n'
              'Acceleration: ${summary.acceleratingGrade.toStringAsFixed(0)}%\n'
              'Turning: ${summary.turningGrade.toStringAsFixed(0)}%',
        ),

        _ReportItem(
          icon: Icons.visibility_outlined,
          title: 'Focused Driving Score',
          value: '${summary.focusedDrivingGrade.toStringAsFixed(0)}%',
        ),

        _ReportItem(
          icon: Icons.drive_eta,
          title: 'Distance Driven',
          value: '${summary.milesDriven.toStringAsFixed(1)} miles',
        ),

        _ReportItem(
          icon: Icons.access_time_rounded,
          title: 'Trip Duration',
          value: formatDuration(summary.elapsed),
        ),

        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb_outline_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Helpful Tip!',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 5),
                      Text(suggestion, style: const TextStyle(fontSize: 16)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ReportItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String? subtitle;

  const _ReportItem({
    required this.icon,
    required this.title,
    required this.value,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
