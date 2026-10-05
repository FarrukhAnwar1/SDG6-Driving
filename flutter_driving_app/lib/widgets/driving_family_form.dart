// Form for creating, joining, or inviting members to a Driving Family
import 'package:flutter/material.dart';

import 'driving_family_api.dart';
import 'error_banner.dart';

enum DrivingFamilyFormKind { create, join, invite }

class DrivingFamilyFormResult {
  const DrivingFamilyFormResult.success(this.value) : error = null;
  const DrivingFamilyFormResult.failure(this.error) : value = '';

  final String value;
  final DrivingFamilyException? error;
}

class DrivingFamilyForm extends StatefulWidget {
  const DrivingFamilyForm({
    super.key,
    required this.kind,
    required this.currentUserEmail,
  });

  final DrivingFamilyFormKind kind;
  final String currentUserEmail;

  @override
  State<DrivingFamilyForm> createState() => _DrivingFamilyFormState();
}

class _DrivingFamilyFormState extends State<DrivingFamilyForm> {
  final _formKey = GlobalKey<FormState>();
  final _controller = TextEditingController();
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validate(String? value) {
    final text = value?.trim() ?? '';
    if (widget.kind == DrivingFamilyFormKind.join) {
      if (text.isEmpty) return 'Enter your join code.';
      if (RegExp(r'\s').hasMatch(text)) {
        return 'Join codes cannot contain spaces.';
      }
    } else if (widget.kind == DrivingFamilyFormKind.invite) {
      if (text.isEmpty) return 'Enter an email address.';
      if (text.length > 254 ||
          !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text)) {
        return 'Enter a valid email address.';
      }
    }
    return null;
  }

  Future<void> _submit() async {
    if (_isSubmitting || !(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    final value = _controller.text.trim();
    try {
      switch (widget.kind) {
        case DrivingFamilyFormKind.create:
          await DrivingFamilyApi.create();
        case DrivingFamilyFormKind.join:
          await DrivingFamilyApi.join(value);
        case DrivingFamilyFormKind.invite:
          await DrivingFamilyApi.invite(value);
      }
      if (!mounted) return;
      // Release the PopScope before closing the successful form
      setState(() => _isSubmitting = false);
      Navigator.of(context).pop(DrivingFamilyFormResult.success(value));
    } on DrivingFamilyException catch (error) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      if (error.shouldRefresh) {
        Navigator.of(context).pop(DrivingFamilyFormResult.failure(error));
      } else {
        setState(() => _error = error.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.kind) {
      DrivingFamilyFormKind.create => 'Create Family',
      DrivingFamilyFormKind.join => 'Join Family',
      DrivingFamilyFormKind.invite => 'Invite a member',
    };
    final description = switch (widget.kind) {
      DrivingFamilyFormKind.create =>
        'Create a Driving Family to share driving summaries. You will be the '
            'admin and can invite or remove members. As admin, you can leave only when you '
            'are the last member.',
      DrivingFamilyFormKind.join =>
        'Enter the single-use join code sent by the family admin. '
            'The invited email must match your signed-in account. '
            'You can belong to one Driving Family at a time.',
      DrivingFamilyFormKind.invite =>
        'We will email a single-use join code to this address. '
            'The recipient must sign in with this email address to join '
            'and share driving summaries with your family.',
    };
    final buttonLabel = switch (widget.kind) {
      DrivingFamilyFormKind.create =>
        _isSubmitting ? 'Creating...' : 'Create Family',
      DrivingFamilyFormKind.join =>
        _isSubmitting ? 'Joining...' : 'Join Family',
      DrivingFamilyFormKind.invite =>
        _isSubmitting ? 'Sending...' : 'Send Invitation',
    };
    return PopScope(
      canPop: !_isSubmitting,
      child: AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(description),
              if (widget.kind == DrivingFamilyFormKind.join) ...[
                const SizedBox(height: 12),
                Text(
                  'Signed in as',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Text(widget.currentUserEmail),
              ],
              if (widget.kind != DrivingFamilyFormKind.create) ...[
                const SizedBox(height: 20),
                TextFormField(
                  controller: _controller,
                  autofocus: true,
                  enabled: !_isSubmitting,
                  autocorrect: false,
                  enableSuggestions:
                      widget.kind == DrivingFamilyFormKind.invite,
                  keyboardType: widget.kind == DrivingFamilyFormKind.invite
                      ? TextInputType.emailAddress
                      : TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: widget.kind == DrivingFamilyFormKind.invite
                        ? 'Email address'
                        : 'Join code',
                    border: const OutlineInputBorder(),
                  ),
                  validator: _validate,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                ErrorBanner(message: _error!),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _isSubmitting ? null : _submit,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isSubmitting) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                Flexible(child: Text(buttonLabel, textAlign: TextAlign.center)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
