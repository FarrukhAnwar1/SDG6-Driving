// Forgot Password Screen
import 'package:flutter/material.dart';
import 'widgets/error_banner.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key, this.onResetPassword});

  // TODO: Implement the callback to handle actual password reset logic
  final Future<void> Function(String email)? onResetPassword;

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  // Spacing constants
  static const double _fieldSpacing = 16;
  static const double _horizontalPadding = 24;

  // Form controllers
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();

  // State variables
  bool _isSubmitting = false;
  bool _emailSent = false;
  String? _submitError;

  static final RegExp _emailRegex = RegExp(r'^[\w\.\-\+]+@[\w\-]+\.[\w\-\.]+$');

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) return 'Enter your email';
    if (!_emailRegex.hasMatch(email)) return 'Enter a valid email address';
    return null;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });

    final email = _emailController.text.trim();

    try {
      if (widget.onResetPassword != null) {
        await widget.onResetPassword!(email);
      } else {
        // Fallback demo call
        await Future<void>.delayed(const Duration(seconds: 2));
      }

      if (!mounted) return;
      setState(() => _emailSent = true);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _submitError = 'Could not send reset email. Please try again.',
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _backToLogin() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  // Building Forgot Password Screen UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Forgot Password')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: _horizontalPadding,
                vertical: 32,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: _emailSent ? _buildSuccessView() : _buildFormView(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFormView() {
    return Form(
      key: _formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Reset your password',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            "Enter the email associated with your account and we'll send "
            'you a link to reset your password.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          if (_submitError != null) ...[
            ErrorBanner(message: _submitError!),
            const SizedBox(height: _fieldSpacing),
          ],

          TextFormField(
            controller: _emailController,
            enabled: !_isSubmitting,
            autocorrect: false,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email',
              prefixIcon: Icon(Icons.email_outlined),
              border: OutlineInputBorder(),
            ),
            validator: _validateEmail,
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 24),

          FilledButton(
            onPressed: _isSubmitting ? null : _submit,
            child: _isSubmitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : const Text('Send reset link'),
          ),
          const SizedBox(height: 8),

          TextButton(
            onPressed: _isSubmitting ? null : _backToLogin,
            child: const Text('Back to login'),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.mark_email_read_outlined,
          size: 64,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Check your email',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'If an account exists for ${_emailController.text.trim()}, '
          "we've sent a link to reset your password.",
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        FilledButton(
          onPressed: _backToLogin,
          child: const Text('Back to login'),
        ),
      ],
    );
  }
}
