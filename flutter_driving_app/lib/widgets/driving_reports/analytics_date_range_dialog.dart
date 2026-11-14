// A scrollable alternative to the range picker's fixed-size input layout.
// Full-width fields preserve the user's text size on compact screens.
import 'package:flutter/material.dart';

class AnalyticsDateRangeDialog extends StatefulWidget {
  const AnalyticsDateRangeDialog({
    super.key,
    required this.firstDate,
    required this.lastDate,
    this.initialDateRange,
  });

  final DateTime firstDate;
  final DateTime lastDate;
  final DateTimeRange? initialDateRange;

  @override
  State<AnalyticsDateRangeDialog> createState() =>
      _AnalyticsDateRangeDialogState();
}

class _AnalyticsDateRangeDialogState extends State<AnalyticsDateRangeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _startController = TextEditingController();
  final _endController = TextEditingController();
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final range = widget.initialDateRange;
    if (range != null) {
      final localizations = MaterialLocalizations.of(context);
      _startController.text = localizations.formatCompactDate(range.start);
      _endController.text = localizations.formatCompactDate(range.end);
    }
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  DateTime? _parse(String text) =>
      MaterialLocalizations.of(context).parseCompactDate(text);

  String? _validate(String? text, {required bool isEnd}) {
    final localizations = MaterialLocalizations.of(context);
    final date = _parse(text ?? '');
    if (date == null) return localizations.invalidDateFormatLabel;
    if (date.isBefore(widget.firstDate) || date.isAfter(widget.lastDate)) {
      return localizations.dateOutOfRangeLabel;
    }
    final start = _parse(_startController.text);
    if (isEnd && start != null && date.isBefore(start)) {
      return localizations.invalidDateRangeLabel;
    }
    return null;
  }

  Future<void> _pickDate({required bool isEnd}) async {
    final controller = isEnd ? _endController : _startController;
    final initial =
        _parse(controller.text) ??
        _parse(_startController.text) ??
        DateUtils.dateOnly(DateTime.now());
    final bounded = initial.isBefore(widget.firstDate)
        ? widget.firstDate
        : initial.isAfter(widget.lastDate)
        ? widget.lastDate
        : initial;
    final selected = await showDatePicker(
      context: context,
      firstDate: widget.firstDate,
      lastDate: widget.lastDate,
      initialDate: bounded,
      helpText: isEnd ? 'Choose end date' : 'Choose start date',
    );
    if (!mounted || selected == null) return;
    controller.text = MaterialLocalizations.of(
      context,
    ).formatCompactDate(selected);
  }

  void _confirm() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      DateTimeRange(
        start: _parse(_startController.text)!,
        end: _parse(_endController.text)!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    Widget field({required bool isEnd}) => TextFormField(
      controller: isEnd ? _endController : _startController,
      keyboardType: TextInputType.datetime,
      textInputAction: isEnd ? TextInputAction.done : TextInputAction.next,
      onFieldSubmitted: isEnd ? (_) => _confirm() : null,
      validator: (text) => _validate(text, isEnd: isEnd),
      decoration: InputDecoration(
        labelText: isEnd
            ? localizations.dateRangeEndLabel
            : localizations.dateRangeStartLabel,
        hintText: localizations.dateHelpText,
        border: const OutlineInputBorder(),
        errorMaxLines: 3,
        suffixIcon: IconButton(
          tooltip: isEnd ? 'Choose end date' : 'Choose start date',
          onPressed: () => _pickDate(isEnd: isEnd),
          icon: const Icon(Icons.calendar_today),
        ),
      ),
    );

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      scrollable: true,
      title: Text(localizations.dateRangePickerHelpText),
      content: SizedBox(
        width: 360,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              field(isEnd: false),
              const SizedBox(height: 20),
              field(isEnd: true),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(localizations.cancelButtonLabel),
        ),
        TextButton(
          onPressed: _confirm,
          child: Text(localizations.okButtonLabel),
        ),
      ],
    );
  }
}
