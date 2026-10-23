// Widget tests for the ForgotPasswordPage
//
// Validates the initial step of the password recovery flow. It ensures
// the email input field rejects empty or malformed text. Additionally,
// it verifies that the "Back to login" button correctly pops
// the current route off the navigation stack to return the user to the previous screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_driving_app/screens/forgot_password_screen.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: child);

  group('ForgotPasswordPage email step validation', () {
    testWidgets('shows an error when submitted empty', (tester) async {
      await tester.pumpWidget(wrap(const ForgotPasswordPage()));

      await tester.tap(find.widgetWithText(FilledButton, 'Send reset code'));
      await tester.pump();

      expect(find.text('Enter your email'), findsOneWidget);
    });

    testWidgets('rejects a malformed email address', (tester) async {
      await tester.pumpWidget(wrap(const ForgotPasswordPage()));

      await tester.enterText(find.byType(TextFormField), 'not-an-email');
      await tester.tap(find.widgetWithText(FilledButton, 'Send reset code'));
      await tester.pump();

      expect(find.text('Enter a valid email address'), findsOneWidget);
    });
  });

  group('ForgotPasswordPage navigation', () {
    testWidgets('"Back to login" pops when there is a previous route', (
      tester,
    ) async {
      // ForgotPasswordPage is normally reached by pushing on top of
      // LoginPage, so canPop() is true and "Back to login" simply pops.
      // Testing it as a standalone "home" would instead hit the
      // pushReplacementNamed('/login') fallback, which needs a routes
      // table this test doesn't set up, so we push it onto a stack here,
      // the same way the real app does.
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ForgotPasswordPage(),
                    ),
                  ),
                  child: const Text('Open forgot password'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open forgot password'));
      await tester.pumpAndSettle();
      expect(find.byType(ForgotPasswordPage), findsOneWidget);

      await tester.tap(find.text('Back to login'));
      await tester.pumpAndSettle();

      expect(find.byType(ForgotPasswordPage), findsNothing);
      expect(find.text('Open forgot password'), findsOneWidget);
    });
  });
}
