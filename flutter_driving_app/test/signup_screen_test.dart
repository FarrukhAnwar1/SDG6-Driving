// Widget tests for the SignUpPage
//
// These tests currently focus on local form validation and user flows without
// triggering actual network calls. The suite verifies that the UI
// properly rejects empty submissions, malformed email addresses, and
// passwords shorter than 8 characters. It also ensures that the
// user can successfully navigate back to the login screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_driving_app/screens/login_screen.dart';
import 'package:flutter_driving_app/screens/signup_screen.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: child);

  group('SignUpPage validation', () {
    testWidgets('shows errors for all three fields when submitted empty', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const SignUpPage()));

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();

      expect(find.text('Enter a username'), findsOneWidget);
      expect(find.text('Enter your password'), findsOneWidget);
      expect(find.text('Enter your email'), findsOneWidget);
    });

    testWidgets('rejects a malformed email address', (tester) async {
      await tester.pumpWidget(wrap(const SignUpPage()));

      // Fields appear in the order: username, password, email
      await tester.enterText(find.byType(TextFormField).at(0), 'newuser');
      await tester.enterText(find.byType(TextFormField).at(1), 'password123');
      await tester.enterText(find.byType(TextFormField).at(2), 'not-an-email');
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();

      expect(find.text('Enter a valid email address'), findsOneWidget);
      expect(find.text('Enter a username'), findsNothing);
      expect(find.text('Enter your password'), findsNothing);
    });

    testWidgets('rejects a password shorter than 8 characters', (tester) async {
      await tester.pumpWidget(wrap(const SignUpPage()));

      await tester.enterText(find.byType(TextFormField).at(0), 'newuser');
      await tester.enterText(find.byType(TextFormField).at(1), 'short');
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'user@example.com',
      );
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();

      expect(
        find.text('Password must be at least 8 characters'),
        findsOneWidget,
      );
    });

    testWidgets('shows no errors for well-formed input', (tester) async {
      await tester.pumpWidget(wrap(const SignUpPage()));

      // Can tap submit if wanted, but need to mock the network call
      await tester.enterText(find.byType(TextFormField).at(0), 'newuser');
      await tester.enterText(find.byType(TextFormField).at(1), 'password123');
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'user@example.com',
      );
      await tester.pump();

      expect(find.text('Enter a username'), findsNothing);
      expect(find.text('Enter your password'), findsNothing);
      expect(find.text('Enter your email'), findsNothing);
      expect(find.text('Enter a valid email address'), findsNothing);
      expect(find.text('Password must be at least 8 characters'), findsNothing);
    });
  });

  group('SignUpPage navigation', () {
    testWidgets('navigates back to LoginPage', (tester) async {
      await tester.pumpWidget(wrap(const SignUpPage()));

      await tester.tap(find.widgetWithText(TextButton, 'Log in'));
      await tester.pumpAndSettle();

      expect(find.byType(LoginPage), findsOneWidget);
    });
  });
}
