// Analytics for the latest 100 saved reports and their recorded violations
import 'dart:convert';
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../widgets/shared/api_config.dart';
import '../widgets/auth/auth_storage.dart';
import '../widgets/driving_reports/driving_report_api.dart';
import '../widgets/driving_reports/driving_report_summary.dart';
import '../widgets/shared/error_banner.dart';
import '../widgets/grading/grade_utils.dart';
import '../widgets/driving/driving_mode.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

enum AnalyticsRange {
  last10(10),
  last25(25),
  last50(50),
  last75(75),
  last100(100);

  const AnalyticsRange(this.limit);
  final int limit;
}

enum AnalyticsTimeOfDay { all, am, pm }

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  List<DrivingReportSummary> _reports = const [];

  String _selectedMetric = 'Overall';
  AnalyticsRange _selectedRange = AnalyticsRange.last100;
  DateTimeRange? _dateRange;
  AnalyticsTimeOfDay _timeOfDay = AnalyticsTimeOfDay.all;

  bool _isLoadingSuggestions = false;
  String? _suggestionsError;
  String? _suggestion;
  int _suggestionsRequestId = 0;

  int get _tripLimit => _selectedRange.limit;

  // Filter the cached history by local trip end date/time, then keep the latest
  // matching trips. No filter change reloads report history from the backend.
  List<DrivingReportSummary> get _filteredReports {
    final matching = _reports.where((report) {
      final date = report.reportDate?.toLocal();
      if (_dateRange != null) {
        if (date == null) return false;
        final day = DateUtils.dateOnly(date);
        if (day.isBefore(_dateRange!.start) || day.isAfter(_dateRange!.end)) {
          return false;
        }
      }
      if (_timeOfDay != AnalyticsTimeOfDay.all) {
        if (date == null) return false;
        final isAm = date.hour < 12;
        if (isAm != (_timeOfDay == AnalyticsTimeOfDay.am)) return false;
      }
      return true;
    }).toList();
    return matching.skip(math.max(0, matching.length - _tripLimit)).toList();
  }

  // Suggestions use the recent-trip count independently of date/time filters
  Future<void> _loadSuggestions() async {
    final requestId = ++_suggestionsRequestId;
    final limit = _tripLimit;
    setState(() {
      _isLoadingSuggestions = true;
      _suggestionsError = null;
      _suggestion = null;
    });

    try {
      final token = await AuthStorage.readToken();

      if (token == null) {
        throw Exception('User is not authorized. Please log in.');
      }

      final response = await http
          .get(
            Uri.parse(
              '${ApiConfig.baseUrl}/advanced-suggestion',
            ).replace(queryParameters: {'limit': '$limit'}),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        throw Exception('Failed to load suggestions');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final message = data['message'] as String;
      if (message.trim().isEmpty) {
        throw const FormatException('Empty suggestion');
      }

      // A slower response for an old selection must not replace newer advice
      if (!mounted || requestId != _suggestionsRequestId) return;

      setState(() {
        _suggestion = message;
        _isLoadingSuggestions = false;
      });
    } catch (_) {
      if (!mounted || requestId != _suggestionsRequestId) return;

      setState(() {
        _suggestionsError = 'Suggestions could not be loaded.';
        _isLoadingSuggestions = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await DrivingReportApi.fetchHistory();

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (result.success) {
        // The chart runs oldest to newest. Reversing preserves the backend's
        // reportDate/id ordering, including trips that ended in the same second.
        _reports = result.reports.reversed.toList();
      } else {
        _errorMessage = result.errorMessage;
      }
    });
    if (result.success) await _loadSuggestions();
  }

  Widget _buildSuggestionsSection() {
    if (_isLoadingSuggestions) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_suggestionsError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ErrorBanner(message: _suggestionsError!),
          TextButton(
            onPressed: _loadSuggestions,
            child: const Text('Retry suggestions'),
          ),
        ],
      );
    }

    if (_suggestion == null || _suggestion!.isEmpty) {
      return const Text('No driving suggestions available yet.');
    }

    return Card(
      child: ListTile(
        leading: const Icon(Icons.lightbulb_outline),
        title: Text(_suggestion!),
      ),
    );
  }

  Future<void> _selectDateRange() async {
    final dates = _reports
        .map((report) => report.reportDate?.toLocal())
        .whereType<DateTime>()
        .map(DateUtils.dateOnly)
        .toList();
    // Keep an existing selection valid if refreshed history has newer bounds
    if (_dateRange case final range?) dates.addAll([range.start, range.end]);
    final today = DateUtils.dateOnly(DateTime.now());
    final firstDate = dates.fold<DateTime>(
      today,
      (earliest, date) => date.isBefore(earliest) ? date : earliest,
    );
    final lastDate = dates.fold<DateTime>(
      today,
      (latest, date) => date.isAfter(latest) ? date : latest,
    );
    final selected = await showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: lastDate,
      initialDateRange: _dateRange,
    );
    if (!mounted || selected == null) return;
    setState(() => _dateRange = selected);
  }

  Widget _buildFilters(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final range = _dateRange;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Recent trips', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final range in AnalyticsRange.values)
                  ChoiceChip(
                    label: Text('${range.limit}'),
                    selected: range == _selectedRange,
                    onSelected: (selected) {
                      if (!selected) return;
                      setState(() => _selectedRange = range);
                      _loadSuggestions();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _selectDateRange,
                  icon: const Icon(Icons.date_range),
                  label: Text(
                    range == null
                        ? 'Date range'
                        : '${localizations.formatShortDate(range.start)} – '
                              '${localizations.formatShortDate(range.end)}',
                  ),
                ),
                if (range != null)
                  IconButton(
                    onPressed: () => setState(() => _dateRange = null),
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear date range',
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<AnalyticsTimeOfDay>(
              segments: const [
                ButtonSegment(
                  value: AnalyticsTimeOfDay.all,
                  label: Text('All day'),
                ),
                ButtonSegment(value: AnalyticsTimeOfDay.am, label: Text('AM')),
                ButtonSegment(value: AnalyticsTimeOfDay.pm, label: Text('PM')),
              ],
              selected: {_timeOfDay},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                setState(() => _timeOfDay = selection.single);
              },
            ),
            const SizedBox(height: 8),
            const Text('Filters use each trip’s end date and local time.'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _loadHistory,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh trip history',
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ErrorBanner(message: _errorMessage!),
            const SizedBox(height: 16),
            FilledButton(onPressed: _loadHistory, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_reports.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.insights, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              'No trips yet. Finish a drive to see your stats here.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      );
    }

    final reports = _filteredReports;
    // Compare the latest matching drive against earlier matching trips only
    final priorTrips = reports.length > 1
        ? reports.sublist(0, reports.length - 1)
        : const <DrivingReportSummary>[];

    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Based on your ${_reports.length} most recent saved '
            'trip${_reports.length == 1 ? '' : 's'} '
            '(up to ${DrivingReportApi.historyLimit}).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          _SectionHeader('Filters'),
          const SizedBox(height: 12),
          _buildFilters(context),
          const SizedBox(height: 12),
          Text(
            'Showing ${reports.length} matching trip${reports.length == 1 ? '' : 's'}.',
          ),
          const SizedBox(height: 28),
          _SectionHeader('Driving Suggestions'),
          const SizedBox(height: 8),
          Text(
            'Based on up to $_tripLimit latest saved trips, across all dates and times.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _buildSuggestionsSection(),
          const SizedBox(height: 28),
          if (reports.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No trips match these filters. Try another range.'),
              ),
            )
          else ...[
            _SectionHeader('Last Drive'),
            const SizedBox(height: 12),
            _LastDriveCard(trip: reports.last, priorTrips: priorTrips),
            const SizedBox(height: 28),

            _SectionHeader('Recent Trip Stats'),
            const SizedBox(height: 12),
            _RecentStatsGrid(reports: reports),
            const SizedBox(height: 28),

            _SectionHeader('Grade History'),
            const SizedBox(height: 16),
            _HistoryChart(reports: reports, selectedMetric: _selectedMetric),
            if (reports.length >= 2) ...[
              const SizedBox(height: 16),
              _MetricDropdown(
                selectedMetric: _selectedMetric,
                onChanged: (label) {
                  setState(() => _selectedMetric = label);
                },
              ),
            ],
          ],
          if (reports.isNotEmpty) ...[
            const SizedBox(height: 28),
            _SectionHeader('Trip Reports'),
            const SizedBox(height: 12),
            for (final report in reports.reversed)
              _ReportCard(key: ValueKey(report.id), report: report),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
    );
  }
}

String _formatReportDate(
  BuildContext context,
  DateTime? date, {
  String separator = ' ',
}) {
  if (date == null) return 'Date unavailable';
  final local = date.toLocal();
  final day = MaterialLocalizations.of(context).formatShortDate(local);
  final time = TimeOfDay.fromDateTime(local).format(context);
  return '$day$separator$time';
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0) return '$hours hr $minutes min';
  final seconds = duration.inSeconds.remainder(60);
  return '$minutes min $seconds sec';
}

class _ReportCard extends StatelessWidget {
  final DrivingReportSummary report;

  const _ReportCard({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final count = report.violations.length;
    return Card(
      child: ExpansionTile(
        key: PageStorageKey(report.id),
        title: Text(_formatReportDate(context, report.reportDate)),
        // Subtitle shows the driving mode (retroactivly), distance, duration, and violation count.
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            _DrivingModeBadge(mode: report.drivingMode),
            const SizedBox(height: 6),
            Text(
              '${report.milesDriven.toStringAsFixed(1)} mi · '
              '${_formatDuration(report.elapsed)}\n'
              '$count recorded violation${count == 1 ? '' : 's'}',
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in report.gradesByLabel.entries)
            _GradeRow(label: entry.key, value: entry.value, averageValue: null),
          const Divider(height: 24),
          if (report.focusedDrivingGrade == null) const _NotTrackedGradeRow(),
          Text(
            'Recorded Violations',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          if (report.violations.isEmpty)
            const Text('No recorded violations for this trip.')
          else
            for (final violation in report.violations)
              _ViolationTile(violation: violation),
        ],
      ),
    );
  }
}

class _DrivingModeBadge extends StatelessWidget {
  final DrivingMode mode;
  const _DrivingModeBadge({required this.mode});
  @override
  Widget build(BuildContext context) {
    final isNavigation = mode == DrivingMode.navigation;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isNavigation
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isNavigation
                ? Icons.navigation_outlined
                : Icons.directions_car_outlined,
            size: 16,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              isNavigation ? 'Navigation Mode' : 'Regular Mode',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

class _ViolationTile extends StatelessWidget {
  final DrivingReportViolation violation;

  const _ViolationTile({required this.violation});

  String _formatTime(DateTime date) {
    final local = date.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour < 12 ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    final roadName = violation.roadName;
    final gradeLabel = switch (violation.violationType) {
      'Proper Speed' => 'Speed',
      'Smooth Braking' => 'Braking',
      'Smooth Accelerating' => 'Acceleration',
      'Smooth Turning' => 'Turning',
      'Focused Driving' => 'Focused Driving',
      _ => null,
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        violation.violationType,
        style: TextStyle(color: metricColors[gradeLabel]),
      ),
      subtitle: Text(
        '${roadName == null || roadName.trim().isEmpty ? 'Road unavailable' : roadName}\n'
        '${_formatTime(violation.startTime)}\n'
        '${_formatDuration(violation.elapsed)}',
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Last Drive
// ---------------------------------------------------------------------------

class _LastDriveCard extends StatelessWidget {
  final DrivingReportSummary trip;
  final List<DrivingReportSummary> priorTrips;

  const _LastDriveCard({required this.trip, required this.priorTrips});

  @override
  Widget build(BuildContext context) {
    final sameModePriorTrips = priorTrips
        .where((report) => report.drivingMode == trip.drivingMode)
        .toList();
    final priorAverages = <String, double>{};
    for (final label in metricColors.keys) {
      // Overall uses a different category set in each driving mode
      final comparableTrips = label == 'Overall'
          ? sameModePriorTrips
          : priorTrips;
      final values = comparableTrips
          .map((report) => report.gradesByLabel[label])
          .whereType<double>()
          .toList();
      if (values.isNotEmpty) {
        priorAverages[label] = values.reduce((a, b) => a + b) / values.length;
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: gradeColorFor(trip.overallGrade),
                  child: Text(
                    letterGradeFor(trip.overallGrade),
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _formatReportDate(context, trip.reportDate),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${trip.milesDriven.toStringAsFixed(1)} mi · ${_formatDuration(trip.elapsed)}',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 28),
            for (final entry in trip.gradesByLabel.entries)
              _GradeRow(
                label: entry.key,
                value: entry.value,
                averageValue: priorAverages[entry.key],
              ),
            const SizedBox(height: 12),
            if (trip.focusedDrivingGrade == null) const _NotTrackedGradeRow(),
            Text(
              priorTrips.isEmpty
                  ? 'Complete another drive to start comparing trips.'
                  : 'Compared with the average of your ${priorTrips.length} prior trip${priorTrips.length == 1 ? '' : 's'}.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
            ),
            if (sameModePriorTrips.length < priorTrips.length)
              Text(
                sameModePriorTrips.isEmpty
                    ? 'Overall comparison needs an earlier trip in this driving mode.'
                    : 'Overall is compared with your ${sameModePriorTrips.length} prior '
                          'trip${sameModePriorTrips.length == 1 ? '' : 's'} in this driving mode.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
              ),
          ],
        ),
      ),
    );
  }
}

class _GradeRow extends StatelessWidget {
  final String label;
  final double value;
  final double? averageValue;

  const _GradeRow({
    required this.label,
    required this.value,
    required this.averageValue,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(radius: 5, backgroundColor: metricColors[label]),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          // Shared column widths keep scores and changes aligned across rows
          SizedBox(
            width: MediaQuery.textScalerOf(context).scale(48),
            child: Text(
              '${value.toStringAsFixed(0)}%',
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          if (averageValue != null) ...[
            const SizedBox(width: 14),
            _GradeChange(delta: value - averageValue!),
          ],
        ],
      ),
    );
  }
}

//Adds a row to the last drive card for grades that are not tracked,
//such as focused driving in navigation mode.
class _NotTrackedGradeRow extends StatelessWidget {
  const _NotTrackedGradeRow();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.remove_circle_outline, size: 12),
          SizedBox(width: 10),
          Expanded(child: Text('Focused Driving')),
          Text('Not Tracked', style: TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _GradeChange extends StatelessWidget {
  final double delta;

  const _GradeChange({required this.delta});

  @override
  Widget build(BuildContext context) {
    final points = delta.round();
    final color = points > 0
        ? Colors.green
        : (points < 0 ? Colors.red : Colors.grey);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: points == 0
              ? null
              : Icon(
                  points > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 20,
                  color: color,
                ),
        ),
        const SizedBox(width: 2),
        SizedBox(
          width: MediaQuery.textScalerOf(context).scale(44),
          child: Text(
            '${points.abs()} pts',
            textAlign: TextAlign.end,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Recent Trip Stats
// ---------------------------------------------------------------------------

class _RecentStatsGrid extends StatelessWidget {
  final List<DrivingReportSummary> reports;
  const _RecentStatsGrid({required this.reports});

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return '$hours hr $minutes min';
  }

  @override
  Widget build(BuildContext context) {
    final tripCount = reports.length;
    final totalMiles = reports.fold<double>(0, (sum, r) => sum + r.milesDriven);
    final totalDuration = reports.fold<Duration>(
      Duration.zero,
      (sum, r) => sum + r.elapsed,
    );
    final avgOverall =
        reports.fold<double>(0, (sum, r) => sum + r.overallGrade) / tripCount;

    final tiles = [
      _StatTile(label: 'Total Trips', value: '$tripCount'),
      _StatTile(
        label: 'Total Distance',
        value: '${totalMiles.toStringAsFixed(1)} mi',
      ),
      _StatTile(
        label: 'Total Drive Time',
        value: _formatDuration(totalDuration),
      ),
      _StatTile(
        label: 'Average Grade',
        value: '${avgOverall.toStringAsFixed(0)}%',
        valueColor: gradeColorFor(avgOverall),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final minTileWidth = MediaQuery.textScalerOf(context).scale(140);
        final columns = constraints.maxWidth >= minTileWidth * 2 + 12 ? 2 : 1;

        // Let each row grow with its text, keeping neighboring cards equal
        // in height without imposing an aspect ratio that can clip content.
        return Column(
          children: [
            for (var i = 0; i < tiles.length; i += columns) ...[
              if (i > 0) const SizedBox(height: 12),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: tiles[i]),
                    if (columns == 2) ...[
                      const SizedBox(width: 12),
                      Expanded(child: tiles[i + 1]),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _StatTile({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: valueColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grade History chart + grade selection
// ---------------------------------------------------------------------------

class _MetricDropdown extends StatelessWidget {
  final String selectedMetric;
  final ValueChanged<String> onChanged;

  const _MetricDropdown({
    required this.selectedMetric,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: selectedMetric,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Grade',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final entry in metricColors.entries)
          DropdownMenuItem(
            value: entry.key,
            child: Row(
              children: [
                CircleAvatar(backgroundColor: entry.value, radius: 6),
                const SizedBox(width: 10),
                Expanded(child: Text(entry.key)),
              ],
            ),
          ),
      ],
      onChanged: (label) {
        if (label != null) onChanged(label);
      },
    );
  }
}

class _HistoryChart extends StatefulWidget {
  final List<DrivingReportSummary> reports;
  final String selectedMetric;

  const _HistoryChart({required this.reports, required this.selectedMetric});

  @override
  State<_HistoryChart> createState() => _HistoryChartState();
}

class _HistoryChartState extends State<_HistoryChart> {
  int? _selectedTripIndex;

  @override
  void didUpdateWidget(covariant _HistoryChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.reports, widget.reports) ||
        oldWidget.selectedMetric != widget.selectedMetric) {
      _selectedTripIndex = null;
    }
  }

  void _selectTrip(int? index) {
    if (_selectedTripIndex == index) return;
    setState(() => _selectedTripIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final reports = widget.reports;
    final selectedMetric = widget.selectedMetric;
    final selectedTripIndex = _selectedTripIndex;

    if (reports.length < 2) {
      return SizedBox(
        height: 120,
        child: Center(
          child: Text(
            'Complete another drive to see grade trends over time.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }

    final availableGrades = [
      for (final report in reports)
        if (report.gradesByLabel[selectedMetric] != null)
          report.gradesByLabel[selectedMetric]!,
    ];
    if (availableGrades.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('No grades available for this metric.')),
      );
    }
    final lastIndex = (reports.length - 1).toDouble();
    const bottomLabelStyle = TextStyle(fontSize: 10);
    final bottomLabels = [
      for (final report in reports)
        report.reportDate == null
            ? 'Unknown'
            : '${report.reportDate!.month}/${report.reportDate!.day}',
    ];
    final labelPainter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    final labelStyle = DefaultTextStyle.of(
      context,
    ).style.merge(bottomLabelStyle);
    var widestLabel = 0.0;
    var tallestLabel = 0.0;
    for (final label in bottomLabels) {
      labelPainter.text = TextSpan(text: label, style: labelStyle);
      labelPainter.layout();
      widestLabel = math.max(widestLabel, labelPainter.width);
      tallestLabel = math.max(tallestLabel, labelPainter.height);
    }
    labelPainter.dispose();
    // Edge labels shift inward, so leave extra room beside both endpoints
    final minimumLabelSpacing = widestLabel * 1.5 + 12;

    final lineBars = <LineChartBarData>[
      LineChartBarData(
        spots: [
          for (var i = 0; i < reports.length; i++)
            reports[i].gradesByLabel[selectedMetric] == null
                ? FlSpot.nullSpot
                : FlSpot(
                    i.toDouble(),
                    reports[i].gradesByLabel[selectedMetric]!,
                  ),
        ],
        isCurved: false,
        color: metricColors[selectedMetric],
        barWidth: 2.5,
        dotData: const FlDotData(show: true),
        belowBarData: BarAreaData(show: false),
        showingIndicators: [
          if (selectedTripIndex != null &&
              reports[selectedTripIndex].gradesByLabel[selectedMetric] != null)
            selectedTripIndex,
        ],
      ),
    ];

    // Recompute the scale for the selected grade. Padding keeps flat
    // histories readable, and rounded bounds give the axis clear tick marks.
    final visibleGrades = availableGrades;
    final lowestGrade = visibleGrades.reduce(math.min);
    final highestGrade = visibleGrades.reduce(math.max);
    final padding = ((highestGrade - lowestGrade) * 0.1).clamp(2.5, 10.0);
    final lowerBound = (lowestGrade - padding).clamp(0.0, 100.0);
    final upperBound = (highestGrade + padding).clamp(0.0, 100.0);
    final interval = [
      1.0,
      2.0,
      5.0,
      10.0,
      20.0,
    ].firstWhere((step) => step >= (upperBound - lowerBound) / 5);
    final minY = ((lowerBound / interval).floor() * interval).clamp(0.0, 100.0);
    final maxY = ((upperBound / interval).ceil() * interval).clamp(0.0, 100.0);

    final selectedSpots = <LineBarSpot>[
      if (selectedTripIndex != null)
        for (var i = 0; i < lineBars.length; i++)
          LineBarSpot(lineBars[i], i, lineBars[i].spots[selectedTripIndex]),
    ];

    return TapRegion(
      onTapOutside: (_) => _selectTrip(null),
      child: GestureDetector(
        // Axis labels and padding also dismiss the popup. Taps in the plot
        // are handled by the chart's own gesture recognizer.
        behavior: HitTestBehavior.opaque,
        onTap: () => _selectTrip(null),
        child: SizedBox(
          height: 260,
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: lastIndex,
                minY: minY,
                maxY: maxY,
                showingTooltipIndicators: [
                  if (selectedSpots.isNotEmpty)
                    ShowingTooltipIndicators(selectedSpots),
                ],
                lineTouchData: LineTouchData(
                  enabled: true,
                  handleBuiltInTouches: false,
                  touchSpotThreshold: 20,
                  distanceCalculator: (touch, spot) => (touch - spot).distance,
                  touchCallback: (event, response) {
                    if (event is! FlTapUpEvent && event is! FlLongPressStart) {
                      return;
                    }
                    final spots = response?.lineBarSpots;
                    _selectTrip(
                      spots == null || spots.isEmpty
                          ? null
                          : spots.first.spotIndex,
                    );
                  },
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => Colors.white,
                    tooltipBorder: const BorderSide(color: Colors.black),
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItems: (touchedSpots) {
                      final items = [
                        for (final spot in touchedSpots)
                          LineTooltipItem(
                            '${spot.y.round()}',
                            TextStyle(
                              color: spot.bar.color,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                      ];
                      if (items.isEmpty) return items;

                      final date = _formatReportDate(
                        context,
                        reports[touchedSpots.first.x.round()].reportDate,
                        separator: '\n',
                      );
                      final firstScore = items.first;

                      // Put the date and time on separate lines above the score
                      items[0] = LineTooltipItem(
                        '$date\n',
                        const TextStyle(
                          color: Colors.black,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        children: [
                          TextSpan(
                            text: firstScore.text,
                            style: firstScore.textStyle,
                          ),
                        ],
                      );
                      return items;
                    },
                  ),
                ),
                gridData: FlGridData(
                  show: true,
                  horizontalInterval: interval,
                  drawVerticalLine: false,
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(color: Colors.grey.shade300),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 34,
                      interval: interval,
                      getTitlesWidget: (value, meta) => Text(
                        value.toInt().toString(),
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: math.max(26.0, tallestLabel + 8),
                      interval: 1,
                      getTitlesWidget: (value, meta) {
                        final index = value.round();
                        if (index < 0 ||
                            index >= reports.length ||
                            meta.parentAxisSize <= 0) {
                          return const SizedBox.shrink();
                        }
                        final pixelsPerTrip = meta.parentAxisSize / lastIndex;
                        final labelStride = math.max(
                          1,
                          (minimumLabelSpacing / pixelsPerTrip).ceil(),
                        );
                        final isLast = index == reports.length - 1;
                        // Label actual trips only, and reserve room for the
                        // final date instead of crowding it with a nearby tick.
                        if (!isLast &&
                            (meta.parentAxisSize < widestLabel * 2 + 12 ||
                                (index != 0 &&
                                    (index % labelStride != 0 ||
                                        (lastIndex - index) * pixelsPerTrip <
                                            minimumLabelSpacing)))) {
                          return const SizedBox.shrink();
                        }
                        return SideTitleWidget(
                          meta: meta,
                          space: 6,
                          fitInside: SideTitleFitInsideData.fromTitleMeta(
                            meta,
                            distanceFromEdge: 0,
                          ),
                          child: Text(
                            bottomLabels[index],
                            style: bottomLabelStyle,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                lineBarsData: lineBars,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
