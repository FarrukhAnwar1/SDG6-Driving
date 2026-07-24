// Widget tests for the LoginPage
//
// Covers purely local widget interactions, explicitly avoiding mocked HTTP
// clients by not testing the final network-hitting submission.
// However, this behavior can be changed in the future, or covered in a separate integration test suite.
// The suite validates email and password input restrictions, the behavior of
// the password visibility toggle, and the routing logic to both the Sign Up
// and Forgot Password screens.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_driving_app/screens/forgot_password_screen.dart';
import 'package:flutter_driving_app/screens/login_screen.dart';
import 'package:flutter_driving_app/screens/signup_screen.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: child);

  group('LoginPage validation', () {
    testWidgets('shows errors for both fields when submitted empty', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const LoginPage()));

      await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
      await tester.pump();

      expect(find.text('Enter your email'), findsOneWidget);
      expect(find.text('Enter your password'), findsOneWidget);
    });

    testWidgets('rejects a malformed email address', (tester) async {
      await tester.pumpWidget(wrap(const LoginPage()));

      // Fields appear in the order: email then password
      await tester.enterText(find.byType(TextFormField).at(0), 'not-an-email');
      await tester.enterText(find.byType(TextFormField).at(1), 'password123');
      await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
      await tester.pump();

      expect(find.text('Enter a valid email address'), findsOneWidget);
      expect(find.text('Enter your password'), findsNothing);
    });

    testWidgets('rejects a password shorter than 8 characters', (tester) async {
      await tester.pumpWidget(wrap(const LoginPage()));

      await tester.enterText(
        find.byType(TextFormField).at(0),
        'user@example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'short');
      await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
      await tester.pump();

      expect(
        find.text('Password must be at least 8 characters'),
        findsOneWidget,
      );
    });

    testWidgets('shows no errors for a well-formed email and password', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const LoginPage()));

      await tester.enterText(
        find.byType(TextFormField).at(0),
        'user@example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'password123');
      await tester.pump();

      expect(find.text('Enter your email'), findsNothing);
      expect(find.text('Enter a valid email address'), findsNothing);
      expect(find.text('Enter your password'), findsNothing);
      expect(find.text('Password must be at least 8 characters'), findsNothing);
    });
  });

  group('LoginPage interactions', () {
    testWidgets('toggles password visibility', (tester) async {
      await tester.pumpWidget(wrap(const LoginPage()));

      expect(find.byTooltip('Show password'), findsOneWidget);

      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();

      expect(find.byTooltip('Hide password'), findsOneWidget);
      expect(find.byTooltip('Show password'), findsNothing);
    });

    testWidgets('navigates to ForgotPasswordPage', (tester) async {
      await tester.pumpWidget(wrap(const LoginPage()));

      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();

      expect(find.byType(ForgotPasswordPage), findsOneWidget);
    });

    testWidgets('navigates to SignUpPage', (tester) async {
      await tester.pumpWidget(wrap(const LoginPage()));

      await tester.tap(find.text('Sign up'));
      await tester.pumpAndSettle();

      expect(find.byType(SignUpPage), findsOneWidget);
    });
  });
}
