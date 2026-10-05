// Driving Family Hub Screen including the main family view, form, and related widgets
import 'package:flutter/material.dart';

import '../widgets/driving_family_api.dart';
import '../widgets/driving_family_form.dart';
import '../widgets/driving_family_summary.dart';
import '../widgets/error_banner.dart';
import '../widgets/grade_utils.dart';

class DrivingFamilyScreen extends StatefulWidget {
  const DrivingFamilyScreen({
    super.key,
    required this.currentUserId,
    required this.currentUserEmail,
  });

  final int currentUserId;
  final String currentUserEmail;

  @override
  State<DrivingFamilyScreen> createState() => _DrivingFamilyScreenState();
}

class _DrivingFamilyScreenState extends State<DrivingFamilyScreen>
    with WidgetsBindingObserver {
  DrivingFamilySummary? _family;
  bool _hasLoaded = false;
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _requestInFlight = false;
  bool _isSubmitting = false;
  bool _dialogOpen = false;
  bool _refreshWhenReady = false;
  String? _loadError;
  String? _actionError;
  String? _notice;

  bool get _busy => _isLoading || _isRefreshing || _isSubmitting || _dialogOpen;
  bool get _canAct => _hasLoaded && !_busy && _loadError == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadFamily();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadFamily();
  }

  Future<void> _loadFamily({bool clearActionError = true}) async {
    if (_requestInFlight) return;
    if (_dialogOpen || _isSubmitting) {
      _refreshWhenReady = true;
      return;
    }
    _requestInFlight = true;
    _refreshWhenReady = false;
    setState(() {
      _isLoading = !_hasLoaded;
      _isRefreshing = _hasLoaded;
      _loadError = null;
      if (clearActionError) _actionError = null;
    });
    try {
      final family = await DrivingFamilyApi.fetchCurrent();
      if (!mounted) return;
      final isMember =
          family?.members.any(
            (member) => member.userId == widget.currentUserId,
          ) ??
          false;
      setState(() {
        if ((_family != null || family != null) && !isMember) {
          _notice =
              'You are no longer a member of this Driving Family. '
              'You can create or join a family below.';
        }
        _family = isMember ? family : null;
        _hasLoaded = true;
      });
    } on DrivingFamilyException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    } finally {
      _requestInFlight = false;
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
        });
      }
    }
  }

  Future<void> _showForm(DrivingFamilyFormKind kind) async {
    if (!_canAct) return;
    if (kind == DrivingFamilyFormKind.invite &&
        _family?.adminUserId != widget.currentUserId) {
      return;
    }
    setState(() {
      _dialogOpen = true;
      _actionError = null;
    });
    final result = await showDialog<DrivingFamilyFormResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DrivingFamilyForm(
        kind: kind,
        currentUserEmail: widget.currentUserEmail,
      ),
    );
    if (!mounted) return;
    setState(() => _dialogOpen = false);
    if (result == null) {
      if (_refreshWhenReady) await _loadFamily();
      return;
    }
    setState(() {
      _actionError = result.error?.message;
      _notice = result.error == null
          ? switch (kind) {
              DrivingFamilyFormKind.create =>
                'Your Driving Family was created.',
              DrivingFamilyFormKind.join => 'You joined the Driving Family.',
              DrivingFamilyFormKind.invite =>
                'Invitation sent to ${result.value}.',
            }
          : null;
    });
    await _loadFamily(clearActionError: false);
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async {
    setState(() => _dialogOpen = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    setState(() => _dialogOpen = false);
    return confirmed == true;
  }

  Future<void> _leave() async {
    final family = _family;
    if (!_canAct || family == null) return;
    final isAdmin = family.adminUserId == widget.currentUserId;
    if (isAdmin && family.members.length > 1) return;
    final confirmed = await _confirm(
      title: 'Leave Driving Family?',
      message: isAdmin
          ? 'You are the last member. Leaving will delete this family and '
                'invalidate its invitations.'
          : 'Your driving summaries will no longer be shared with this family. '
                'You will need a new invitation to rejoin.',
      action: 'Leave Family',
    );
    if (!mounted) return;
    if (confirmed) {
      await _runMutation(
        DrivingFamilyApi.leave,
        'You left the Driving Family.',
        leaving: true,
      );
    } else if (_refreshWhenReady) {
      await _loadFamily();
    }
  }

  Future<void> _remove(FamilyMemberSummary member) async {
    final family = _family;
    if (!_canAct ||
        family == null ||
        family.adminUserId != widget.currentUserId ||
        member.userId == widget.currentUserId) {
      return;
    }
    final confirmed = await _confirm(
      title: 'Remove ${member.username}?',
      message:
          'Their driving summaries will no longer be shared with this '
          'family. They will need a new invitation to rejoin.',
      action: 'Remove Member',
    );
    if (!mounted) return;
    if (confirmed) {
      await _runMutation(
        () => DrivingFamilyApi.removeMember(member.userId),
        '${member.username} was removed from the family.',
      );
    } else if (_refreshWhenReady) {
      await _loadFamily();
    }
  }

  Future<void> _runMutation(
    Future<void> Function() action,
    String notice, {
    bool leaving = false,
  }) async {
    if (!_canAct) return;
    setState(() {
      _isSubmitting = true;
      _actionError = null;
      _notice = null;
    });
    var refresh = false;
    try {
      await action();
      if (mounted) {
        setState(() {
          _notice = notice;
          if (leaving) _family = null;
        });
      }
      refresh = true;
    } on DrivingFamilyException catch (error) {
      if (mounted) setState(() => _actionError = error.message);
      refresh = error.shouldRefresh;
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
    if (mounted && (refresh || _refreshWhenReady)) {
      await _loadFamily(clearActionError: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isSubmitting,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Driving Family'),
          actions: [
            IconButton(
              onPressed: _busy ? null : _loadFamily,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh Driving Family',
            ),
          ],
        ),
        body: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _loadFamily,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(20),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_isRefreshing || _isSubmitting) ...[
                                const LinearProgressIndicator(),
                                const SizedBox(height: 16),
                              ],
                              if (_loadError != null) ...[
                                ErrorBanner(message: _loadError!),
                                if (_hasLoaded) ...[
                                  const SizedBox(height: 8),
                                  const Text(
                                    'Refresh to update your membership '
                                    'and summaries and use family controls.',
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    onPressed: _busy ? null : _loadFamily,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Retry'),
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                              if (_actionError != null) ...[
                                ErrorBanner(message: _actionError!),
                                const SizedBox(height: 16),
                              ],
                              if (_notice != null) ...[
                                _FamilyNotice(message: _notice!),
                                const SizedBox(height: 16),
                              ],
                              if (_hasLoaded)
                                if (_family == null)
                                  _buildNoFamily(context)
                                else
                                  ..._buildFamily(context, _family!),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildNoFamily(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.groups_outlined,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 20),
            Text(
              'No Driving Family yet',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text(
              'Share progress with the people you drive with. See each member\'s '
              'average scores, latest drive, total driving time, and distance.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'You can belong to one family at a time.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _canAct
                  ? () => _showForm(DrivingFamilyFormKind.create)
                  : null,
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Create Family'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _canAct
                  ? () => _showForm(DrivingFamilyFormKind.join)
                  : null,
              icon: const Icon(Icons.login),
              label: const Text('Join Family'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildFamily(BuildContext context, DrivingFamilySummary family) {
    final theme = Theme.of(context);
    final isAdmin = family.adminUserId == widget.currentUserId;
    final adminCannotLeave = isAdmin && family.members.length > 1;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Your Driving Family', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                '${family.members.length} '
                '${family.members.length == 1 ? 'member' : 'members'} '
                '\u00b7 Admin: ${family.admin.username}',
              ),
              const SizedBox(height: 16),
              if (isAdmin)
                FilledButton.icon(
                  onPressed: _canAct
                      ? () => _showForm(DrivingFamilyFormKind.invite)
                      : null,
                  icon: const Icon(Icons.mail_outline),
                  label: const Text('Invite a Member'),
                )
              else
                const Text('Only the family admin can invite new members.'),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      Text('Members', style: theme.textTheme.titleLarge),
      const SizedBox(height: 4),
      const Text(
        'Scores and totals are based on all saved driving reports. '
        'Pull down or refresh to see new reports.',
      ),
      const SizedBox(height: 12),
      for (final member in family.members) ...[
        _FamilyMemberCard(
          key: ValueKey('family-member-${member.userId}'),
          member: member,
          isAdmin: member.userId == family.adminUserId,
          isCurrentUser: member.userId == widget.currentUserId,
          onRemove: isAdmin && member.userId != widget.currentUserId
              ? (_canAct ? () => _remove(member) : null)
              : null,
          showRemove: isAdmin && member.userId != widget.currentUserId,
        ),
        const SizedBox(height: 12),
      ],
      const SizedBox(height: 12),
      if (adminCannotLeave) ...[
        const Text(
          'As admin, you can leave only when you are the last member. '
          'Remove the other members first.',
        ),
        const SizedBox(height: 12),
      ] else if (isAdmin) ...[
        const Text('You are the last member. Leaving will delete this family.'),
        const SizedBox(height: 12),
      ],
      OutlinedButton.icon(
        onPressed: _canAct && !adminCannotLeave ? _leave : null,
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.error,
        ),
        icon: const Icon(Icons.exit_to_app),
        label: const Text('Leave Family'),
      ),
    ];
  }
}

class _FamilyNotice extends StatelessWidget {
  const _FamilyNotice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colors.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _FamilyMemberCard extends StatelessWidget {
  const _FamilyMemberCard({
    super.key,
    required this.member,
    required this.isAdmin,
    required this.isCurrentUser,
    required this.showRemove,
    required this.onRemove,
  });

  final FamilyMemberSummary member;
  final bool isAdmin;
  final bool isCurrentUser;
  final bool showRemove;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = member.latestDrive?.reportDate?.toLocal();
    final latestLabel = date == null
        ? 'Latest drive: Date unavailable'
        : 'Latest drive: ${MaterialLocalizations.of(context).formatShortDate(date)} '
              '${TimeOfDay.fromDateTime(date).format(context)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(child: Icon(Icons.person_outline)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(member.username, style: theme.textTheme.titleMedium),
                      if (isAdmin || isCurrentUser)
                        Text(
                          [
                            if (isAdmin) 'Admin',
                            if (isCurrentUser) 'You',
                          ].join(' \u00b7 '),
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (showRemove)
                  IconButton(
                    onPressed: onRemove,
                    icon: const Icon(Icons.person_remove_outlined),
                    tooltip: 'Remove ${member.username}',
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (member.driveCount == 0)
              const Text(
                'No saved drives yet. Scores will appear after a report is saved.',
              )
            else ...[
              Text(
                '${member.driveCount} saved '
                '${member.driveCount == 1 ? 'drive' : 'drives'}',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                member.latestDrive == null
                    ? 'Latest drive: Unavailable'
                    : latestLabel,
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(1.6),
                1: FlexColumnWidth(),
                2: FlexColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  children: [
                    _cell('Category', style: theme.textTheme.labelLarge),
                    _cell(
                      'Average',
                      style: theme.textTheme.labelLarge,
                      align: TextAlign.right,
                    ),
                    _cell(
                      'Latest',
                      style: theme.textTheme.labelLarge,
                      align: TextAlign.right,
                    ),
                  ],
                ),
                for (final label in FamilyGrades.fieldsByLabel.keys)
                  TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: metricColors[label],
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(label)),
                          ],
                        ),
                      ),
                      _cell(
                        _score(member.averageGrades?.byLabel[label]),
                        align: TextAlign.right,
                      ),
                      _cell(
                        _score(member.latestDrive?.grades.byLabel[label]),
                        align: TextAlign.right,
                      ),
                    ],
                  ),
              ],
            ),
            const Divider(height: 28),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _total(
                  context,
                  Icons.timer_outlined,
                  'Driving time',
                  _duration(member.totalDrivingMinutes),
                ),
                _total(
                  context,
                  Icons.route_outlined,
                  'Total distance',
                  '${member.totalDistanceMiles.toStringAsFixed(1)} mi',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(String text, {TextStyle? style, TextAlign? align}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Text(text, style: style, textAlign: align),
  );

  Widget _total(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 8),
      Flexible(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(value, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
      ),
    ],
  );

  String _score(double? value) {
    if (value == null) return '\u2014';
    final precision = value == value.roundToDouble() ? 0 : 1;
    return '${value.toStringAsFixed(precision)}% (${letterGradeFor(value)})';
  }

  String _duration(double minutes) {
    final duration = Duration(seconds: (minutes * 60).round());
    if (duration.inHours > 0) {
      return '${duration.inHours} hr ${duration.inMinutes.remainder(60)} min';
    }
    final seconds = duration.inSeconds.remainder(60);
    return seconds == 0
        ? '${duration.inMinutes} min'
        : '${duration.inMinutes} min $seconds sec';
  }
}
