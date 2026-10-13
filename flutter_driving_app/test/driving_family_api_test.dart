// Tests for the Driving Family API including create, join, invite, and leave functionality
import 'dart:convert';

import 'package:flutter_driving_app/widgets/driving_family_api.dart';
import 'package:flutter_driving_app/widgets/driving_family_summary.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/driving_family_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test-token'});
  });

  test(
    'reads separate average and latest scores and lifetime totals',
    () async {
      final family = await http.runWithClient(
        DrivingFamilyApi.fetchCurrent,
        () => MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/families/me');
          expect(request.headers['Authorization'], 'Bearer test-token');
          return http.Response(jsonEncode(familyResponse()), 200);
        }),
      );
      expect(family!.admin.username, 'Alex');
      final member = family.members.first;
      expect(member.averageGrades!.byLabel['Overall'], 88);
      expect(member.latestDrive!.grades.byLabel['Overall'], 93);
      expect(member.averageGrades!.byLabel.keys, [
        'Overall',
        'Speed',
        'Braking',
        'Acceleration',
        'Turning',
        'Focused Driving',
      ]);
      expect(member.latestDrive!.reportDate, DateTime.utc(2026, 10, 5, 14, 30));
      expect(member.totalDrivingMinutes, 90.5);
      expect(member.totalDistanceMiles, 45.6);
      expect(family.members.last.driveCount, 0);
      expect(family.members.last.averageGrades, isNull);
      expect(family.members.last.latestDrive, isNull);
    },
  );

  test('only explicit empty responses count as no membership', () async {
    for (final response in [
      http.Response('{"family":null}', 200),
      http.Response('', 204),
    ]) {
      expect(
        await http.runWithClient(
          DrivingFamilyApi.fetchCurrent,
          () => MockClient((_) async => response),
        ),
        isNull,
      );
    }
    for (final response in [
      http.Response('{"detail":"Not Found"}', 404),
      http.Response('{}', 200),
      http.Response('not json', 200),
      http.Response('{"family":{"id":7}}', 200),
    ]) {
      await expectLater(
        http.runWithClient(
          DrivingFamilyApi.fetchCurrent,
          () => MockClient((_) async => response),
        ),
        throwsA(isA<DrivingFamilyException>()),
      );
    }
  });

  test(
    'sends authenticated mutations and preserves the opaque join code',
    () async {
      final paths = <String>[];
      await http.runWithClient(
        () async {
          await DrivingFamilyApi.create();
          await DrivingFamilyApi.join('  aB_123-XYZ  ');
          await DrivingFamilyApi.invite('  sam@example.com  ');
          await DrivingFamilyApi.leave();
          await DrivingFamilyApi.removeMember(2);
        },
        () => MockClient((request) async {
          paths.add(request.url.path);
          expect(request.headers['Authorization'], 'Bearer test-token');
          if (request.url.path.endsWith('/members/2')) {
            expect(request.method, 'DELETE');
          } else {
            expect(request.method, 'POST');
            expect(request.headers['Content-Type'], 'application/json');
            final body = jsonDecode(request.body);
            if (request.url.path.endsWith('/join')) {
              expect(body, {'code': 'aB_123-XYZ'});
            } else if (request.url.path.endsWith('/invitations')) {
              expect(body, {'email': 'sam@example.com'});
            } else {
              expect(body, isEmpty);
            }
          }
          return http.Response('', 204);
        }),
      );
      expect(paths, [
        '/families',
        '/families/join',
        '/families/me/invitations',
        '/families/leave',
        '/families/me/members/2',
      ]);
    },
  );

  test(
    'missing credentials send no request and expired sessions are clear',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      await expectLater(
        http.runWithClient(
          DrivingFamilyApi.fetchCurrent,
          () => MockClient((_) async => fail('Unexpected network request')),
        ),
        throwsA(
          isA<DrivingFamilyException>().having(
            (e) => e.message,
            'message',
            contains('Please log in'),
          ),
        ),
      );
      FlutterSecureStorage.setMockInitialValues({'access_token': 'test-token'});
      await expectLater(
        http.runWithClient(
          DrivingFamilyApi.fetchCurrent,
          () => MockClient((_) async => http.Response('{}', 401)),
        ),
        throwsA(
          isA<DrivingFamilyException>().having(
            (e) => e.message,
            'message',
            'Session expired. Please log in again.',
          ),
        ),
      );
    },
  );

  test(
    'membership errors require refresh and validation details are displayed',
    () async {
      for (final status in [403, 404, 409]) {
        await expectLater(
          http.runWithClient(
            () => DrivingFamilyApi.invite('sam@example.com'),
            () => MockClient(
              (_) async =>
                  http.Response('{"detail":"Membership changed"}', status),
            ),
          ),
          throwsA(
            isA<DrivingFamilyException>()
                .having((e) => e.shouldRefresh, 'shouldRefresh', isTrue)
                .having((e) => e.message, 'message', 'Membership changed'),
          ),
        );
      }
      await expectLater(
        http.runWithClient(
          () => DrivingFamilyApi.join('bad'),
          () => MockClient(
            (_) async => http.Response(
              '{"detail":[{"msg":"Invalid or expired join code"}]}',
              422,
            ),
          ),
        ),
        throwsA(
          isA<DrivingFamilyException>().having(
            (e) => e.message,
            'message',
            'Invalid or expired join code',
          ),
        ),
      );
    },
  );

  test('connection errors become retryable messages', () async {
    await expectLater(
      http.runWithClient(
        DrivingFamilyApi.fetchCurrent,
        () => MockClient((_) async => throw http.ClientException('Offline')),
      ),
      throwsA(
        isA<DrivingFamilyException>().having(
          (e) => e.message,
          'message',
          contains('Check your connection'),
        ),
      ),
    );
  });

  test(
    'invitation errors keep the join form open with useful fallback messages',
    () async {
      for (final error in [
        (
          code: 'invitation_already_used',
          status: 409,
          text: 'already been used',
        ),
        (
          code: 'invitation_email_mismatch',
          status: 403,
          text: 'different email address',
        ),
        (code: 'invalid_invitation', status: 400, text: 'join code is invalid'),
      ]) {
        for (final body in [
          {
            'detail': {'code': error.code},
          },
          {'code': error.code},
        ]) {
          await expectLater(
            http.runWithClient(
              () => DrivingFamilyApi.join('opaque-Code'),
              () => MockClient(
                (_) async => http.Response(jsonEncode(body), error.status),
              ),
            ),
            throwsA(
              isA<DrivingFamilyException>()
                  .having((e) => e.errorCode, 'errorCode', error.code)
                  .having((e) => e.shouldRefresh, 'shouldRefresh', isFalse)
                  .having((e) => e.message, 'message', contains(error.text)),
            ),
          );
        }
      }
    },
  );

  test(
    'structured admin errors preserve the server message and refresh permissions',
    () async {
      const message = 'Only the family admin can invite others.';
      await expectLater(
        http.runWithClient(
          () => DrivingFamilyApi.invite('sam@example.com'),
          () => MockClient(
            (_) async => http.Response(
              jsonEncode({
                'detail': {'code': 'admin_required', 'message': message},
              }),
              403,
            ),
          ),
        ),
        throwsA(
          isA<DrivingFamilyException>()
              .having((e) => e.errorCode, 'errorCode', 'admin_required')
              .having((e) => e.shouldRefresh, 'shouldRefresh', isTrue)
              .having((e) => e.message, 'message', message),
        ),
      );
    },
  );

  test(
    'bad membership and totals are rejected rather than displaying fake stats',
    () {
      final json = familyResponse()['family'] as Map<String, dynamic>;
      json['adminUserId'] = 99;
      expect(() => DrivingFamilySummary.fromJson(json), throwsFormatException);
      final member = familyMemberJson();
      member['totalDrivingMinutes'] = -1;
      expect(() => FamilyMemberSummary.fromJson(member), throwsFormatException);
      member['totalDrivingMinutes'] = 30;
      (member['averageGrades'] as Map<String, dynamic>)['overallGrade'] = 101;
      expect(() => FamilyMemberSummary.fromJson(member), throwsFormatException);
    },
  );
}
