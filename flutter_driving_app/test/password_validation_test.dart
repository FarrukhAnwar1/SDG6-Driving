// Tests UTF-8 password byte limits across authentication forms.

import 'package:flutter/material.dart';
import 'package:flutter_driving_app/screens/change_password_screen.dart';
import 'package:flutter_driving_app/screens/login_screen.dart';
import 'package:flutter_driving_app/screens/signup_screen.dart';
import 'package:flutter_driving_app/screens/forgot_password_screen.dart';
import 'package:flutter_driving_app/widgets/password_validation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('password limits count UTF-8 bytes rather than characters', () {
    expect(passwordByteLengthError('x' * 72), isNull);
    expect(passwordByteLengthError('é' * 36), isNull);
    expect(passwordByteLengthError('x' * 73), contains('72 UTF-8 bytes'));
    expect(passwordByteLengthError('é' * 37), contains('72 UTF-8 bytes'));
    expect(passwordByteLengthError('😀' * 19), contains('72 UTF-8 bytes'));
  });

  for (final entry in [
    (screen: const LoginPage(), index: 1),
    (screen: const SignUpPage(), index: 2),
    (screen: const ChangePasswordPage(), index: 1),
  ]) {
    testWidgets(
      '${entry.screen.runtimeType} rejects an oversized Unicode password',
      (tester) async {
        await tester.pumpWidget(MaterialApp(home: entry.screen));
        await tester.enterText(
          find.byType(TextFormField).at(entry.index),
          'é' * 40,
        );
        final form = tester.state<FormState>(find.byType(Form));
        expect(form.validate(), isFalse);
        await tester.pump();
        expect(
          find.text('Password must be at most 72 UTF-8 bytes.'),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'password reset rejects oversized Unicode before sending the reset',
    (tester) async {
      var requests = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            const MaterialApp(home: ForgotPasswordPage()),
          );
          await tester.enterText(
            find.byType(TextFormField),
            'driver@example.test',
          );
          await tester.tap(find.text('Send reset code'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextFormField).at(0), '123456');
          await tester.enterText(find.byType(TextFormField).at(1), 'é' * 40);
          await tester.enterText(find.byType(TextFormField).at(2), 'é' * 40);
          tester.state<FormState>(find.byType(Form)).validate();
          await tester.pump();
          expect(
            find.text('Password must be at most 72 UTF-8 bytes.'),
            findsOneWidget,
          );
          expect(requests, 1);
        },
        () => MockClient((request) async {
          requests++;
          expect(request.url.path, '/forgot-password');
          return http.Response('{}', 200);
        }),
      );
    },
  );
}
