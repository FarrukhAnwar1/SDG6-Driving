// Forgot Password Screen
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../widgets/error_banner.dart';

enum _ForgotPasswordStep { email, resetCode, success }

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  // Spacing constants
  static const double _fieldSpacing = 16;
  static const double _horizontalPadding = 24;

  // Backend URL (Android emulator)
  static const String baseUrl = 'http://10.0.2.2:8000';

  // Form keys (one per step, since fields differ)
  final _emailFormKey = GlobalKey<FormState>();
  final _resetFormKey = GlobalKey<FormState>();

  // Form controllers
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  // State variables
  _ForgotPasswordStep _step = _ForgotPasswordStep.email;
  bool _isSubmitting = false;
  bool _isResendingCode = false;
  bool _obscureNewPassword = true;
  bool _obscureConfirmPassword = true;
  String? _submitError;

  static final RegExp _emailRegex = RegExp(r'^[\w\.\-\+]+@[\w\-]+\.[\w\-\.]+$');
  static final RegExp _codeRegex = RegExp(r'^\d{6}$');

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) return 'Enter your email';
    if (!_emailRegex.hasMatch(email)) return 'Enter a valid email address';
    return null;
  }

  String? _validateCode(String? value) {
    final code = value?.trim() ?? '';
    if (code.isEmpty) return 'Enter the code from your email';
    if (!_codeRegex.hasMatch(code)) return 'Enter the 6-digit code';
    return null;
  }

  String? _validateNewPassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Enter a new password';
    if (password.length < 8) return 'Password must be at least 8 characters';
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value != _newPasswordController.text) return 'Passwords do not match';
    return null;
  }

  // Request a 6-digit code be emailed to the account
  Future<void> _requestCode() async {
    FocusScope.of(context).unfocus();

    final isValid = _emailFormKey.currentState?.validate() ?? false;
    if (!isValid || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/forgot-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': _emailController.text.trim()}),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() => _step = _ForgotPasswordStep.resetCode);
      } else {
        setState(
          () => _submitError = 'Could not send reset code. Please try again.',
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitError = 'Could not connect to backend.');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  // Lets the user request a fresh code without retyping their email
  Future<void> _resendCode() async {
    if (_isResendingCode) return;

    setState(() => _isResendingCode = true);

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/forgot-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': _emailController.text.trim()}),
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            response.statusCode == 200
                ? 'A new code has been sent to your email.'
                : 'Could not resend the code. Please try again.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not connect to backend.')),
      );
    } finally {
      if (mounted) setState(() => _isResendingCode = false);
    }
  }

  // Submit the code + new password together
  Future<void> _resetPassword() async {
    FocusScope.of(context).unfocus();

    final isValid = _resetFormKey.currentState?.validate() ?? false;
    if (!isValid || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/reset-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': _emailController.text.trim(),
          'code': _codeController.text.trim(),
          'new_password': _newPasswordController.text,
        }),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() => _step = _ForgotPasswordStep.success);
      } else if (response.statusCode == 429) {
        setState(
          () => _submitError =
              'Too many attempts. Please request a new code.',
        );
      } else {
        setState(
          () => _submitError = 'Invalid or expired code. Please try again.',
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitError = 'Could not connect to backend.');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _backToLogin() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  void _changeEmail() {
    setState(() {
      _step = _ForgotPasswordStep.email;
      _submitError = null;
      _codeController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
    });
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
                child: IntrinsicHeight(child: _buildStep()),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case _ForgotPasswordStep.email:
        return _buildEmailStep();
      case _ForgotPasswordStep.resetCode:
        return _buildResetCodeStep();
      case _ForgotPasswordStep.success:
        return _buildSuccessStep();
    }
  }

  Widget _buildEmailStep() {
    return Form(
      key: _emailFormKey,
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
            'you a code to reset your password.',
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
            onFieldSubmitted: (_) => _requestCode(),
          ),
          const SizedBox(height: 24),

          FilledButton(
            onPressed: _isSubmitting ? null : _requestCode,
            child: _isSubmitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : const Text('Send reset code'),
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

  Widget _buildResetCodeStep() {
    return Form(
      key: _resetFormKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.mark_email_read_outlined,
            size: 48,
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
            "If an account exists for ${_emailController.text.trim()}, "
            "we've sent a 6-digit code. Enter it below with your new "
            'password.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          if (_submitError != null) ...[
            ErrorBanner(message: _submitError!),
            const SizedBox(height: _fieldSpacing),
          ],

          TextFormField(
            controller: _codeController,
            enabled: !_isSubmitting,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: '6-digit code',
              prefixIcon: Icon(Icons.pin_outlined),
              border: OutlineInputBorder(),
              counterText: '',
            ),
            validator: _validateCode,
          ),
          const SizedBox(height: _fieldSpacing),

          TextFormField(
            controller: _newPasswordController,
            enabled: !_isSubmitting,
            obscureText: _obscureNewPassword,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.newPassword],
            decoration: InputDecoration(
              labelText: 'New password',
              prefixIcon: const Icon(Icons.lock_outline),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureNewPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                tooltip: _obscureNewPassword ? 'Show password' : 'Hide password',
                onPressed: () {
                  setState(() => _obscureNewPassword = !_obscureNewPassword);
                },
              ),
            ),
            validator: _validateNewPassword,
          ),
          const SizedBox(height: _fieldSpacing),

          TextFormField(
            controller: _confirmPasswordController,
            enabled: !_isSubmitting,
            obscureText: _obscureConfirmPassword,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Confirm new password',
              prefixIcon: const Icon(Icons.lock_outline),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureConfirmPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                tooltip: _obscureConfirmPassword
                    ? 'Show password'
                    : 'Hide password',
                onPressed: () {
                  setState(
                    () => _obscureConfirmPassword = !_obscureConfirmPassword,
                  );
                },
              ),
            ),
            validator: _validateConfirmPassword,
            onFieldSubmitted: (_) => _resetPassword(),
          ),
          const SizedBox(height: 24),

          FilledButton(
            onPressed: _isSubmitting ? null : _resetPassword,
            child: _isSubmitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : const Text('Reset password'),
          ),
          const SizedBox(height: 8),

          TextButton(
            onPressed: _isResendingCode ? null : _resendCode,
            child: _isResendingCode
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text("Didn't get a code? Resend"),
          ),
          TextButton(
            onPressed: _isSubmitting ? null : _changeEmail,
            child: const Text('Use a different email'),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 64,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Password reset',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Your password has been reset successfully. You can now log in '
          'with your new password.',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        FilledButton(onPressed: _backToLogin, child: const Text('Back to login')),
      ],
    );
  }
}
