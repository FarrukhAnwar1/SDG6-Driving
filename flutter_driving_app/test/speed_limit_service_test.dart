// Tests posted, inferred, unknown, malformed, and failed speed-limit responses
import 'dart:async';
import 'dart:convert';
import 'package:flutter_driving_app/widgets/speed_limit_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<SpeedLimit?> fetchLimit(http.Client client) => http.runWithClient(
  () => SpeedLimitService.fetchSpeedLimit(
    latitude: 40.03,
    longitude: -75.01,
    token: 'test-token',
  ),
  () => client,
);

void main() {
  for (final source in ['posted', 'inferred', 'unknown']) {
    test('reads the $source limit, road and tolerance together', () async {
      final result = await fetchLimit(
        MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/speed-limit');
          expect(request.url.queryParameters, {
            'lat': '40.03',
            'lng': '-75.01',
          });
          expect(request.headers['Authorization'], 'Bearer test-token');
          return http.Response(
            jsonEncode({
              'speedLimitMph': source == 'unknown' ? null : 25,
              'speedLimitSource': source,
              'speedingThresholdMph': switch (source) {
                'posted' => 5,
                'inferred' => 15,
                _ => null,
              },
              'roadName': 'Nearest Road',
              'distanceMeters': 3.5,
            }),
            200,
          );
        }),
      );

      expect(result, isNotNull);
      expect(result!.source.name, source);
      expect(result.roadName, 'Nearest Road');
      expect(result.distanceMeters, 3.5);
      expect(result.canGrade, source != 'unknown');
      expect(result.speedLimitMph, source == 'unknown' ? null : 25);
      expect(result.speedingThresholdMph, switch (source) {
        'posted' => 5,
        'inferred' => 15,
        _ => null,
      });
    });
  }

  test('a successful lookup can find no road at all', () async {
    final result = await fetchLimit(
      MockClient(
        (_) async => http.Response(
          '{"speedLimitMph":null,"speedLimitSource":"unknown",'
          '"speedingThresholdMph":null,"roadName":null,"distanceMeters":null}',
          200,
        ),
      ),
    );
    expect(result!.canGrade, isFalse);
    expect(result.roadName, isNull);
    expect(result.distanceMeters, isNull);
  });

  test('missing or invalid grading metadata never falls back to 5 mph', () {
    for (final fields in <Map<String, dynamic>>[
      {'speedLimitSource': 'inferred'},
      {'speedingThresholdMph': 5},
      {'speedLimitSource': 'unknown', 'speedingThresholdMph': 5},
      {'speedLimitSource': 'future-source', 'speedingThresholdMph': 5},
      {'speedLimitSource': 'posted', 'speedingThresholdMph': -1},
    ]) {
      final result = SpeedLimit.fromJson({'speedLimitMph': 25, ...fields});
      expect(result.canGrade, isFalse);
    }
  });

  test('failed and malformed lookups return no cached limit', () async {
    for (final response in [
      http.Response('{}', 401),
      http.Response('{}', 500),
      http.Response('not json', 200),
      http.Response('[]', 200),
      http.Response('{"speedLimitMph":"25"}', 200),
    ]) {
      expect(await fetchLimit(MockClient((_) async => response)), isNull);
    }
    for (final error in [
      http.ClientException('Offline'),
      TimeoutException('No response'),
    ]) {
      expect(await fetchLimit(MockClient((_) async => throw error)), isNull);
    }
  });
}
