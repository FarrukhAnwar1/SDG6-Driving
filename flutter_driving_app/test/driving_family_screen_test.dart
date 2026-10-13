// Tests for the Driving Family screen including creation, joining, inviting, and leaving functionality
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_driving_app/screens/driving_family_screen.dart';
import 'package:flutter_driving_app/screens/home_screen.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/driving_family_fixtures.dart';

http.Response _family({
  List<Map<String, dynamic>>? members,
  int adminUserId = 1,
}) => http.Response(
  jsonEncode(familyResponse(members: members, adminUserId: adminUserId)),
  200,
);

Future<void> _withScreen(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) handler,
  Future<void> Function() exercise, {
  int currentUserId = 1,
  String currentUserEmail = 'alex@example.com',
  bool settle = true,
  double textScale = 1,
}) => http.runWithClient(() async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: DrivingFamilyScreen(
        currentUserId: currentUserId,
        currentUserEmail: currentUserEmail,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  await exercise();
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
}, () => MockClient(handler));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _dialogButton(String label) => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.widgetWithText(FilledButton, label),
);

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test-token'});
  });

  testWidgets('Home opens Driving Family using the signed-in profile', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: HomePage()));
        await tester.pumpAndSettle();
        await _tap(
          tester,
          find.widgetWithText(OutlinedButton, 'Driving Family'),
        );
        expect(find.byType(DrivingFamilyScreen), findsOneWidget);
        expect(
          tester
              .widget<DrivingFamilyScreen>(find.byType(DrivingFamilyScreen))
              .currentUserId,
          1,
        );
        expect(
          tester
              .widget<DrivingFamilyScreen>(find.byType(DrivingFamilyScreen))
              .currentUserEmail,
          'alex@example.com',
        );
        expect(find.text('No Driving Family yet'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      () => MockClient(
        (request) async => request.url.path == '/me'
            ? http.Response(
                '{"id":1,"username":"Alex","email":"alex@example.com"}',
                200,
              )
            : http.Response('{"family":null}', 200),
      ),
    );
  });

  testWidgets('initial loading waits for membership before offering actions', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    await _withScreen(tester, (_) => response.future, () async {
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Create Family'), findsNothing);
      response.complete(http.Response('{"family":null}', 200));
      await tester.pumpAndSettle();
      expect(find.text('Create Family'), findsOneWidget);
      expect(find.text('Join Family'), findsOneWidget);
    }, settle: false);
  });

  testWidgets(
    'a missing endpoint shows retry and does not imply no membership',
    (tester) async {
      var requests = 0;
      await _withScreen(
        tester,
        (_) async => ++requests == 1
            ? http.Response('{}', 404)
            : http.Response('{"family":null}', 200),
        () async {
          expect(
            find.text('Driving Family is unavailable. Please try again later.'),
            findsOneWidget,
          );
          expect(find.text('Create Family'), findsNothing);
          await _tap(tester, find.text('Retry'));
          expect(find.text('No Driving Family yet'), findsOneWidget);
          expect(requests, 2);
        },
      );
    },
  );

  testWidgets('creation explains admin rules and reloads the created family', (
    tester,
  ) async {
    var created = false;
    await _withScreen(
      tester,
      (request) async {
        if (request.method == 'POST') {
          expect(request.url.path, '/families');
          created = true;
          return http.Response('', 201);
        }
        return created
            ? _family(members: [familyMemberJson()])
            : http.Response('{"family":null}', 200);
      },
      () async {
        await _tap(tester, find.text('Create Family'));
        expect(find.textContaining('You will be the admin'), findsOneWidget);
        expect(created, isFalse);
        await _tap(tester, _dialogButton('Create Family'));
        expect(created, isTrue);
        expect(find.text('Your Driving Family was created.'), findsOneWidget);
        expect(find.text('Your Driving Family'), findsOneWidget);
        expect(find.text('Create Family'), findsNothing);
      },
    );
  });

  testWidgets(
    'join validates and keeps an invalid code available for correction',
    (tester) async {
      var posts = 0;
      var joined = false;
      await _withScreen(
        tester,
        (request) async {
          if (request.method == 'POST') {
            expect(request.url.path, '/families/join');
            expect(
              jsonDecode(request.body)['code'],
              posts == 0 ? 'bad-Code' : 'aB_123-XYZ',
            );
            posts++;
            if (posts == 1) {
              return http.Response(
                '{"detail":"Invalid or expired join code"}',
                400,
              );
            }
            joined = true;
            return http.Response('', 204);
          }
          return joined ? _family() : http.Response('{"family":null}', 200);
        },
        () async {
          await _tap(tester, find.text('Join Family'));
          await _tap(tester, _dialogButton('Join Family'));
          expect(find.text('Enter your join code.'), findsOneWidget);
          await tester.enterText(find.byType(TextFormField), 'bad code');
          await _tap(tester, _dialogButton('Join Family'));
          expect(
            find.text('Join codes cannot contain spaces.'),
            findsOneWidget,
          );
          expect(posts, 0);
          await tester.enterText(find.byType(TextFormField), ' bad-Code ');
          await _tap(tester, _dialogButton('Join Family'));
          expect(find.text('Invalid or expired join code'), findsOneWidget);
          expect(find.byType(AlertDialog), findsOneWidget);
          await tester.enterText(find.byType(TextFormField), ' aB_123-XYZ ');
          await _tap(tester, _dialogButton('Join Family'));
          expect(posts, 2);
          expect(find.text('You joined the Driving Family.'), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
        },
      );
    },
  );

  testWidgets(
    'all six average/latest scores, totals and no-drive members are shown',
    (tester) async {
      await _withScreen(tester, (_) async => _family(), () async {
        final alex = find.byKey(const ValueKey('family-member-1'));
        expect(
          find.descendant(of: alex, matching: find.text('88% (B)')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: alex, matching: find.text('93% (A)')),
          findsOneWidget,
        );
        for (final label in [
          'Overall',
          'Speed',
          'Braking',
          'Acceleration',
          'Turning',
          'Focused Driving',
        ]) {
          expect(
            find.descendant(of: alex, matching: find.text(label)),
            findsOneWidget,
          );
        }
        expect(
          find.descendant(of: alex, matching: find.text('1 hr 30 min')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: alex, matching: find.text('45.6 mi')),
          findsOneWidget,
        );
        final sam = find.byKey(const ValueKey('family-member-2'));
        expect(
          find.descendant(
            of: sam,
            matching: find.textContaining('No saved drives yet'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: sam, matching: find.text('\u2014')),
          findsNWidgets(12),
        );
        expect(
          find.descendant(of: sam, matching: find.text('0.0 mi')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: sam, matching: find.text('0% (F)')),
          findsNothing,
        );
      });
    },
  );

  for (final error in [
    (
      code: 'invitation_already_used',
      status: 409,
      message:
          'This join code has already been used. Ask the family admin for a new invitation.',
    ),
    (
      code: 'invitation_email_mismatch',
      status: 403,
      message:
          'This invitation was sent to a different email address. Sign in with the account that received it.',
    ),
  ]) {
    testWidgets('join keeps ${error.code} errors beside the signed-in email', (
      tester,
    ) async {
      var joins = 0;
      var reads = 0;
      await _withScreen(
        tester,
        (request) async {
          if (request.method == 'POST') {
            joins++;
            expect(request.url.path, '/families/join');
            // The account identity comes from authentication, not a submitted email
            expect(jsonDecode(request.body), {'code': 'single-use-Code'});
            return http.Response(
              jsonEncode({
                'detail': {'code': error.code},
              }),
              error.status,
            );
          }
          reads++;
          return http.Response('{"family":null}', 200);
        },
        () async {
          await _tap(tester, find.text('Join Family'));
          expect(find.textContaining('single-use join code'), findsOneWidget);
          expect(
            find.textContaining(
              'The invited email must match your signed-in account',
            ),
            findsOneWidget,
          );
          expect(find.text('Signed in as'), findsOneWidget);
          expect(find.text('alex@example.com'), findsOneWidget);
          await tester.enterText(find.byType(TextFormField), 'single-use-Code');
          await _tap(tester, _dialogButton('Join Family'));
          expect(find.text(error.message), findsOneWidget);
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(find.text('You joined the Driving Family.'), findsNothing);
          expect(
            tester
                .widget<TextFormField>(find.byType(TextFormField))
                .controller!
                .text,
            'single-use-Code',
          );
          expect(joins, 1);
          expect(reads, 1);
          await _tap(tester, find.text('Cancel'));
          expect(find.text('No Driving Family yet'), findsOneWidget);
        },
      );
    });
  }

  testWidgets(
    'invitation validates, prevents duplicate sends, retries and confirms success',
    (tester) async {
      var invites = 0;
      final firstSend = Completer<http.Response>();
      await _withScreen(
        tester,
        (request) async {
          if (request.method == 'POST') {
            invites++;
            expect(request.url.path, '/families/me/invitations');
            expect(jsonDecode(request.body), {'email': 'sam@example.com'});
            return invites == 1 ? firstSend.future : http.Response('', 204);
          }
          return _family();
        },
        () async {
          await _tap(tester, find.text('Invite a Member'));
          expect(find.textContaining('single-use join code'), findsOneWidget);
          expect(
            find.textContaining('must sign in with this email address'),
            findsOneWidget,
          );
          await _tap(tester, _dialogButton('Send Invitation'));
          expect(find.text('Enter an email address.'), findsOneWidget);
          await tester.enterText(find.byType(TextFormField), 'invalid');
          await _tap(tester, _dialogButton('Send Invitation'));
          expect(find.text('Enter a valid email address.'), findsOneWidget);
          expect(invites, 0);
          await tester.enterText(
            find.byType(TextFormField),
            ' sam@example.com ',
          );
          await tester.tap(_dialogButton('Send Invitation'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 20));
          expect(find.text('Sending...'), findsOneWidget);
          expect(
            tester.widget<FilledButton>(_dialogButton('Sending...')).onPressed,
            isNull,
          );
          expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
                .onPressed,
            isNull,
          );
          expect(invites, 1);
          firstSend.complete(http.Response('{}', 500));
          await tester.pumpAndSettle();
          expect(
            find.text('Could not send the invitation. Please try again.'),
            findsOneWidget,
          );
          expect(find.byType(TextFormField), findsOneWidget);
          await _tap(tester, _dialogButton('Send Invitation'));
          expect(invites, 2);
          expect(
            find.text('Invitation sent to sam@example.com.'),
            findsOneWidget,
          );
          expect(find.byType(AlertDialog), findsNothing);
        },
      );
    },
  );

  testWidgets(
    'admin removal is confirmed and the last admin can leave and delete',
    (tester) async {
      var removed = false;
      var left = false;
      var deletions = 0;
      var leaves = 0;
      await _withScreen(
        tester,
        (request) async {
          if (request.method == 'DELETE') {
            expect(request.url.path, '/families/me/members/2');
            deletions++;
            removed = true;
            return http.Response('', 204);
          }
          if (request.method == 'POST') {
            expect(request.url.path, '/families/leave');
            leaves++;
            left = true;
            return http.Response('', 204);
          }
          if (left) return http.Response('{"family":null}', 200);
          return removed ? _family(members: [familyMemberJson()]) : _family();
        },
        () async {
          final leave = find.widgetWithText(OutlinedButton, 'Leave Family');
          expect(tester.widget<OutlinedButton>(leave).onPressed, isNull);
          expect(
            find.textContaining('Remove the other members first.'),
            findsOneWidget,
          );
          expect(find.byTooltip('Remove Alex'), findsNothing);
          await _tap(tester, find.byTooltip('Remove Sam'));
          expect(find.text('Remove Sam?'), findsOneWidget);
          await _tap(tester, find.text('Cancel'));
          expect(deletions, 0);
          await _tap(tester, find.byTooltip('Remove Sam'));
          await _tap(tester, _dialogButton('Remove Member'));
          expect(deletions, 1);
          expect(find.byKey(const ValueKey('family-member-2')), findsNothing);
          expect(find.text('Sam was removed from the family.'), findsOneWidget);
          expect(tester.widget<OutlinedButton>(leave).onPressed, isNotNull);
          await _tap(tester, leave);
          expect(
            find.textContaining('invalidate its invitations'),
            findsOneWidget,
          );
          await _tap(tester, find.text('Cancel'));
          expect(leaves, 0);
          await _tap(tester, leave);
          await _tap(tester, _dialogButton('Leave Family'));
          expect(leaves, 1);
          expect(find.text('You left the Driving Family.'), findsOneWidget);
          expect(find.text('No Driving Family yet'), findsOneWidget);
        },
      );
    },
  );

  testWidgets('a regular member has no removal controls and can leave', (
    tester,
  ) async {
    var left = false;
    await _withScreen(
      tester,
      (request) async {
        if (request.method == 'POST') {
          expect(request.url.path, '/families/leave');
          left = true;
          return http.Response('', 204);
        }
        return left ? http.Response('{"family":null}', 200) : _family();
      },
      () async {
        expect(find.byIcon(Icons.person_remove_outlined), findsNothing);
        expect(find.text('Invite a Member'), findsNothing);
        expect(
          find.text('Only the family admin can invite new members.'),
          findsOneWidget,
        );
        await _tap(tester, find.text('Leave Family'));
        expect(
          find.textContaining(
            'Your driving summaries will no longer be shared',
          ),
          findsOneWidget,
        );
        await _tap(tester, _dialogButton('Leave Family'));
        expect(find.text('No Driving Family yet'), findsOneWidget);
      },
      currentUserId: 2,
      currentUserEmail: 'sam@example.com',
    );
  });

  testWidgets(
    'failed refresh retains summaries, disables actions, then updates reports and membership',
    (tester) async {
      var requests = 0;
      await _withScreen(
        tester,
        (_) async {
          requests++;
          return switch (requests) {
            1 => _family(),
            2 => http.Response('{}', 500),
            3 => _family(
              members: [
                familyMemberJson(averageOverall: 91, latestOverall: 85),
              ],
            ),
            _ => http.Response('{"family":null}', 200),
          };
        },
        () async {
          await _tap(tester, find.byTooltip('Refresh Driving Family'));
          expect(
            find.text('Could not load your Driving Family.'),
            findsOneWidget,
          );
          expect(find.text('Alex'), findsOneWidget);
          expect(find.text('88% (B)'), findsOneWidget);
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Invite a Member'),
                )
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.person_remove_outlined),
                )
                .onPressed,
            isNull,
          );
          await _tap(tester, find.text('Retry'));
          expect(find.text('91% (A)'), findsOneWidget);
          expect(find.text('88% (B)'), findsNothing);
          await _tap(tester, find.byTooltip('Refresh Driving Family'));
          expect(find.byKey(const ValueKey('family-member-1')), findsNothing);
          expect(find.text('No Driving Family yet'), findsOneWidget);
          expect(
            find.textContaining('You are no longer a member'),
            findsOneWidget,
          );
          expect(requests, 4);
        },
      );
    },
  );

  testWidgets(
    'membership loss during an invitation closes stale controls and reloads',
    (tester) async {
      var kicked = false;
      await _withScreen(
        tester,
        (request) async {
          if (request.method == 'POST') {
            kicked = true;
            return http.Response(
              '{"detail":"You are no longer a member"}',
              403,
            );
          }
          return kicked ? http.Response('{"family":null}', 200) : _family();
        },
        () async {
          await _tap(tester, find.text('Invite a Member'));
          await tester.enterText(find.byType(TextFormField), 'sam@example.com');
          await _tap(tester, _dialogButton('Send Invitation'));
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.text('You are no longer a member'), findsOneWidget);
          expect(find.text('No Driving Family yet'), findsOneWidget);
          expect(find.text('Invite a Member'), findsNothing);
        },
      );
    },
  );

  testWidgets(
    'losing admin permission closes the invite form and hides its control',
    (tester) async {
      var lostPermission = false;
      var invites = 0;
      await _withScreen(
        tester,
        (request) async {
          if (request.method == 'POST') {
            invites++;
            lostPermission = true;
            return http.Response('{"detail":{"code":"admin_required"}}', 403);
          }
          return _family(adminUserId: lostPermission ? 2 : 1);
        },
        () async {
          await _tap(tester, find.text('Invite a Member'));
          await tester.enterText(find.byType(TextFormField), 'sam@example.com');
          await _tap(tester, _dialogButton('Send Invitation'));
          expect(
            find.text('Only the family admin can send invitations.'),
            findsOneWidget,
          );
          expect(
            find.text('Only the family admin can invite new members.'),
            findsOneWidget,
          );
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.text('Invite a Member'), findsNothing);
          expect(find.text('Your Driving Family'), findsOneWidget);
          expect(invites, 1);
        },
      );
    },
  );

  testWidgets('membership loss replaces an earlier invitation success notice', (
    tester,
  ) async {
    var reads = 0;
    await _withScreen(
      tester,
      (request) async {
        if (request.method == 'POST') return http.Response('', 204);
        return ++reads < 3 ? _family() : http.Response('{"family":null}', 200);
      },
      () async {
        await _tap(tester, find.text('Invite a Member'));
        await tester.enterText(find.byType(TextFormField), 'sam@example.com');
        await _tap(tester, _dialogButton('Send Invitation'));
        expect(
          find.text('Invitation sent to sam@example.com.'),
          findsOneWidget,
        );
        await _tap(tester, find.byTooltip('Refresh Driving Family'));
        expect(
          find.textContaining('You are no longer a member'),
          findsOneWidget,
        );
        expect(find.text('Invitation sent to sam@example.com.'), findsNothing);
        expect(find.text('No Driving Family yet'), findsOneWidget);
      },
    );
  });

  testWidgets('resuming the app refreshes newly saved reports', (tester) async {
    var requests = 0;
    await _withScreen(
      tester,
      (_) async => _family(
        members: [familyMemberJson(latestOverall: ++requests == 1 ? 93 : 99)],
      ),
      () async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.text('99% (A)'), findsOneWidget);
        expect(requests, 2);
      },
    );
  });

  testWidgets('member cards and dialogs fit a narrow screen with larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _withScreen(
      tester,
      (_) async => _family(
        members: [
          familyMemberJson(username: 'A driver with a very long display name'),
        ],
      ),
      () async {
        await tester.ensureVisible(find.text('Focused Driving'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Leave Family'));
        await tester.pumpAndSettle();
        await _tap(tester, find.text('Invite a Member'));
        expect(find.byType(TextFormField), findsOneWidget);
        await _tap(tester, find.text('Cancel'));
      },
      textScale: 1.5,
    );
  });
}
