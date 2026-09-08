/*
Shown after a trip ends. Displays the trip summary and sends
the driving report to the backend.
*/
import 'package:flutter/material.dart';
import '../widgets/driving_report_api.dart';
import 'trip_summary.dart';

class DrivingReportScreen extends StatefulWidget {
  final TripSummary summary;

  const DrivingReportScreen({super.key, required this.summary});

  @override
  State<DrivingReportScreen> createState() => _DrivingReportScreenState();
}

class _DrivingReportScreenState extends State<DrivingReportScreen> {
  bool _isSending = true;
  bool _sentSuccessfully = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _sendReport();
  }

  Future<void> _sendReport() async {
    final summary = widget.summary;

    final result = await DrivingReportApi.sendReport(
      startTime: summary.startTime,
      endTime: summary.endTime,
      elapsed: summary.elapsed,
      milesDriven: summary.milesDriven,
      overallGrade: summary.overallGrade,
      properSpeedGrade: summary.properSpeedGrade,
    );

    if (!mounted) return;

    setState(() {
      _isSending = false;
      _sentSuccessfully = result.success;
      _errorMessage = result.errorMessage;
    });
  }

  String _formatElapsed(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(d.inHours);
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return d.inHours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Driving Report'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isSending) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 8),
                const Center(child: Text('Sending report...')),
              ] else if (_sentSuccessfully) ...[
                const SizedBox(height: 16),
                const Center(
                  child: Icon(Icons.check_circle, color: Colors.green, size: 48),
                ),
                const SizedBox(height: 8),
                const Center(child: Text('Report sent successfully')),
              ] else ...[
                const SizedBox(height: 16),
                const Center(
                  child: Icon(Icons.error_outline, color: Colors.red, size: 48),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    _errorMessage ?? 'Failed to send report.',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() => _isSending = true);
                      _sendReport();
                    },
                    child: const Text('Retry'),
                  ),
                ),
              ],
              const SizedBox(height: 32),
              _buildGradeCard(context, 'Overall Grade', summary.overallGrade),
              const SizedBox(height: 12),
              _buildGradeCard(context, 'Proper Speed', summary.properSpeedGrade),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _buildStat(
                      context,
                      'Time Elapsed',
                      _formatElapsed(summary.elapsed),
                    ),
                  ),
                  Expanded(
                    child: _buildStat(
                      context,
                      'Miles Driven',
                      summary.milesDriven.toStringAsFixed(1),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              FilledButton(
                onPressed: () {
                  Navigator.of(context).popUntil((route) => route.isFirst);
                },
                child: const Text('Back to Home'),
              ),
            ],
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

  Widget _buildStat(BuildContext context, String label, String value) {
    return Column(
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.titleLarge),
      ],
    );
  }
}