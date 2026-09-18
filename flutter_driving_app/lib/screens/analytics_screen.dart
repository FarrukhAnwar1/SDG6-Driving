// Analytics for the latest 100 saved reports and their recorded violations
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../widgets/driving_report_api.dart';
import '../widgets/driving_report_summary.dart';
import '../widgets/error_banner.dart';
import '../widgets/grade_utils.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  List<DrivingReportSummary> _reports = const [];

  // Controls which metric lines are currently shown on the history chart.
  // Defaults to everything on. The legend chips toggle these values,
  // and the chart rebuilds when the map changes.
  final Map<String, bool> _visibleMetrics = {
    for (final label in metricColors.keys) label: true,
  };

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

    final lastTrip = _reports.last;
    // Compared against prior trips only, so the last drive isn't measured
    // against an average that includes itself.
    final priorTrips = _reports.length > 1
        ? _reports.sublist(0, _reports.length - 1)
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
          _SectionHeader('Last Drive'),
          const SizedBox(height: 12),
          _LastDriveCard(trip: lastTrip, priorTrips: priorTrips),
          const SizedBox(height: 28),

          _SectionHeader('Recent Trip Stats'),
          const SizedBox(height: 12),
          _RecentStatsGrid(reports: _reports),
          const SizedBox(height: 28),

          _SectionHeader('Grade History'),
          const SizedBox(height: 16),
          _HistoryChart(reports: _reports, visibleMetrics: _visibleMetrics),
          if (_reports.length >= 2) ...[
            const SizedBox(height: 16),
            Text(
              'Tap a chip to show or hide that grade.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            _MetricLegend(
              visibleMetrics: _visibleMetrics,
              onToggle: (label, selected) {
                setState(() => _visibleMetrics[label] = selected);
              },
            ),
          ],
          const SizedBox(height: 28),
          _SectionHeader('Trip Reports'),
          const SizedBox(height: 12),
          for (final report in _reports.reversed)
            _ReportCard(key: ValueKey(report.id), report: report),
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

String _formatReportDate(BuildContext context, DateTime? date) {
  if (date == null) return 'Date unavailable';
  final local = date.toLocal();
  final day = MaterialLocalizations.of(context).formatShortDate(local);
  final time = TimeOfDay.fromDateTime(local).format(context);
  return '$day $time';
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
        subtitle: Text(
          '${report.milesDriven.toStringAsFixed(1)} mi · '
          '${_formatDuration(report.elapsed)}\n'
          '$count recorded violation${count == 1 ? '' : 's'}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in report.gradesByLabel.entries)
            _GradeRow(label: entry.key, value: entry.value, averageValue: null),
          const Divider(height: 24),
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

class _ViolationTile extends StatelessWidget {
  final DrivingReportViolation violation;

  const _ViolationTile({required this.violation});

  String _formatTime(BuildContext context, DateTime date) {
    final local = date.toLocal();
    final day = MaterialLocalizations.of(context).formatShortDate(local);
    String pad(int value) => value.toString().padLeft(2, '0');
    return '$day ${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final roadName = violation.roadName;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(violation.violationType),
      subtitle: Text(
        '${roadName == null || roadName.trim().isEmpty ? 'Road unavailable' : roadName}\n'
        '${_formatTime(context, violation.startTime)} – '
        '${_formatTime(context, violation.endTime)}\n'
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
    final priorAverages = priorTrips.isEmpty
        ? null
        : {
            for (final label in metricColors.keys)
              label:
                  priorTrips.fold<double>(
                    0,
                    (sum, report) => sum + report.gradesByLabel[label]!,
                  ) /
                  priorTrips.length,
          };

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
                averageValue: priorAverages?[entry.key],
              ),
            const SizedBox(height: 12),
            Text(
              priorTrips.isEmpty
                  ? 'Complete another drive to start comparing trips.'
                  : 'Compared with the average of your ${priorTrips.length} prior trip${priorTrips.length == 1 ? '' : 's'}.',
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
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(label),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${value.toStringAsFixed(0)}%',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (averageValue != null)
                      _GradeChange(delta: value - averageValue!),
                  ],
                ),
              ],
            ),
          ),
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
        if (points != 0) ...[
          Icon(
            points > 0 ? Icons.arrow_upward : Icons.arrow_downward,
            size: 20,
            color: color,
          ),
          const SizedBox(width: 2),
        ],
        Text(
          '${points.abs()} pts',
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
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
// Grade History chart + legend/toggles
// ---------------------------------------------------------------------------

class _MetricLegend extends StatelessWidget {
  final Map<String, bool> visibleMetrics;
  final void Function(String label, bool selected) onToggle;

  const _MetricLegend({required this.visibleMetrics, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: metricColors.entries.map((entry) {
        final label = entry.key;
        final color = entry.value;
        final selected = visibleMetrics[label] ?? true;
        return FilterChip(
          label: Text(label),
          selected: selected,
          showCheckmark: false,
          avatar: CircleAvatar(backgroundColor: color, radius: 6),
          selectedColor: color.withValues(alpha: 0.16),
          onSelected: (value) => onToggle(label, value),
        );
      }).toList(),
    );
  }
}

class _HistoryChart extends StatefulWidget {
  final List<DrivingReportSummary> reports;
  final Map<String, bool> visibleMetrics;

  const _HistoryChart({required this.reports, required this.visibleMetrics});

  @override
  State<_HistoryChart> createState() => _HistoryChartState();
}

class _HistoryChartState extends State<_HistoryChart> {
  int? _selectedTripIndex;

  @override
  void didUpdateWidget(covariant _HistoryChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.reports, widget.reports)) {
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
    final visibleMetrics = widget.visibleMetrics;
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

    final lastIndex = (reports.length - 1).toDouble();
    final bottomInterval = (reports.length / 5)
        .clamp(1, reports.length)
        .toDouble();

    // Keep labels in chart-series order, including when grades are hidden
    final visibleMetricEntries = metricColors.entries
        .where((entry) => visibleMetrics[entry.key] ?? true)
        .toList();
    final lineBars = <LineChartBarData>[
      for (final entry in visibleMetricEntries)
        LineChartBarData(
          spots: [
            for (var i = 0; i < reports.length; i++)
              FlSpot(i.toDouble(), reports[i].gradesByLabel[entry.key]!),
          ],
          isCurved: false,
          color: entry.value,
          barWidth: 2.5,
          dotData: const FlDotData(show: true),
          belowBarData: BarAreaData(show: false),
          showingIndicators: [?selectedTripIndex],
        ),
    ];

    if (lineBars.isEmpty) {
      return SizedBox(
        height: 260,
        child: Center(
          child: Text(
            'Select a grade below to see its history.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }

    // Recompute the scale from only the visible lines. Padding keeps flat
    // histories readable, and rounded bounds give the axis clear tick marks.
    final visibleGrades = lineBars.expand((line) => line.spots.map((s) => s.y));
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
    ]..sort((a, b) => b.y.compareTo(a.y));

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
                            '${visibleMetricEntries[spot.barIndex].key[0]}: ${spot.y.round()}',
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
                      );
                      final firstScore = items.first;

                      // Show the trip timestamp once, above the colored scores.
                      items[0] = LineTooltipItem(
                        '$date\n',
                        const TextStyle(
                          color: Colors.black,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
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
                      reservedSize: 26,
                      interval: bottomInterval,
                      getTitlesWidget: (value, meta) {
                        final index = value.round();
                        if (index < 0 || index >= reports.length) {
                          return const SizedBox.shrink();
                        }
                        final date = reports[index].reportDate;
                        return SideTitleWidget(
                          meta: meta,
                          space: 6,
                          child: Text(
                            date == null
                                ? 'Unknown'
                                : '${date.month}/${date.day}',
                            style: const TextStyle(fontSize: 10),
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
