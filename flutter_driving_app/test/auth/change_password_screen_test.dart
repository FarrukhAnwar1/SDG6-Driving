// Widget tests for the ChangePasswordPage
//
// This suite comprehensively tests the validation rules for updating a user's
// credentials. It ensures the form requires all fields, enforces
// a minimum length of 8 characters for the new password, prevents reusing the
// current password, and strictly checks that the new password matches the
// confirmation field. It also verifies that the visibility toggles
// for the password fields work correctly.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_driving_app/screens/change_password_screen.dart';

void main() {
  group('ChangePasswordPage validation', () {
    testWidgets('shows errors for all three fields when submitted empty', (
      tester,
    ) async {
      await tester.pumpWidget(MaterialApp(home: const ChangePasswordPage()));

      await tester.tap(find.widgetWithText(FilledButton, 'Update password'));
      await tester.pump();

      expect(find.text('Please enter your current password.'), findsOneWidget);
      expect(find.text('Please enter a new password.'), findsOneWidget);
      expect(find.text('Please confirm your new password.'), findsOneWidget);
    });

    testWidgets('rejects a new password shorter than 8 characters', (
      tester,
    ) async {
      await tester.pumpWidget(MaterialApp(home: const ChangePasswordPage()));

      // Fields appear in the order: current, new, confirm
      await tester.enterText(find.byType(TextFormField).at(0), 'oldpassword1');
      await tester.enterText(find.byType(TextFormField).at(1), 'short');
      await tester.enterText(find.byType(TextFormField).at(2), 'short');
      await tester.tap(find.widgetWithText(FilledButton, 'Update password'));
      await tester.pump();

      expect(
        find.text('Password must be at least 8 characters.'),
        findsOneWidget,
      );
    });

    testWidgets('rejects a new password that matches the current password', (
      tester,
    ) async {
      await tester.pumpWidget(MaterialApp(home: const ChangePasswordPage()));

      await tester.enterText(find.byType(TextFormField).at(0), 'samepassword1');
      await tester.enterText(find.byType(TextFormField).at(1), 'samepassword1');
      await tester.enterText(find.byType(TextFormField).at(2), 'samepassword1');
      await tester.tap(find.widgetWithText(FilledButton, 'Update password'));
      await tester.pump();

      expect(
        find.text('New password must be different from the current password.'),
        findsOneWidget,
      );
    });

    testWidgets('rejects a confirmation that does not match the new password', (
      tester,
    ) async {
      await tester.pumpWidget(MaterialApp(home: const ChangePasswordPage()));

      await tester.enterText(find.byType(TextFormField).at(0), 'oldpassword1');
      await tester.enterText(find.byType(TextFormField).at(1), 'newpassword1');
      await tester.enterText(find.byType(TextFormField).at(2), 'somethingelse');
      await tester.tap(find.widgetWithText(FilledButton, 'Update password'));
      await tester.pump();

      expect(find.text('Passwords do not match.'), findsOneWidget);
    });
  });

  group('ChangePasswordPage interactions', () {
    testWidgets('toggles the new password field visibility', (tester) async {
      await tester.pumpWidget(MaterialApp(home: const ChangePasswordPage()));

      // Three fields, each with its own show/hide toggle, all start hidden
      expect(find.byIcon(Icons.visibility_outlined), findsNWidgets(3));

      // Index 1 is the "New password" field's toggle
      await tester.tap(find.byIcon(Icons.visibility_outlined).at(1));
      await tester.pump();

      expect(find.byIcon(Icons.visibility_outlined), findsNWidgets(2));
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    });
  });
}
