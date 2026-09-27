// Speed Limit API call service
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'api_config.dart';

enum SpeedLimitSource { posted, inferred, unknown }

class SpeedLimit {
  final double? speedLimitMph;
  final SpeedLimitSource source;
  final double? speedingThresholdMph;
  final String? roadName;
  final double? distanceMeters;

  const SpeedLimit({
    required this.speedLimitMph,
    required this.source,
    required this.speedingThresholdMph,
    this.roadName,
    this.distanceMeters,
  });

  // A number without its source and tolerance is not enough to grade safely
  bool get canGrade =>
      source != SpeedLimitSource.unknown &&
      speedLimitMph != null &&
      speedLimitMph!.isFinite &&
      speedLimitMph! >= 0 &&
      speedingThresholdMph != null &&
      speedingThresholdMph!.isFinite &&
      speedingThresholdMph! >= 0;

  factory SpeedLimit.fromJson(Map<String, dynamic> json) => SpeedLimit(
    speedLimitMph: (json['speedLimitMph'] as num?)?.toDouble(),
    source: switch (json['speedLimitSource']) {
      'posted' => SpeedLimitSource.posted,
      'inferred' => SpeedLimitSource.inferred,
      _ => SpeedLimitSource.unknown,
    },
    speedingThresholdMph: (json['speedingThresholdMph'] as num?)?.toDouble(),
    roadName: json['roadName'] as String?,
    distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
  );
}

class SpeedLimitService {
  SpeedLimitService._();

  // An unknown limit can still identify the road. Null means the lookup failed.
  static Future<SpeedLimit?> fetchSpeedLimit({
    required double latitude,
    required double longitude,
    required String token,
  }) async {
    debugPrint(
      'SpeedLimitService: fetching speed limit for '
      'lat=$latitude, lng=$longitude',
    );
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/speed-limit',
    ).replace(queryParameters: {'lat': '$latitude', 'lng': '$longitude'});

    try {
      final response = await http
          .get(uri, headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 2));

      debugPrint(
        'SpeedLimitService: GET $uri -> '
        '${response.statusCode} ${response.body}',
      );

      if (response.statusCode != 200) {
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return SpeedLimit.fromJson(data);
    } on TimeoutException {
      debugPrint(
        'SpeedLimitService: Request timed out after 2 seconds '
        '(lat=$latitude, lng=$longitude)',
      );
      return null;
    } catch (e, st) {
      debugPrint('SpeedLimitService: Request failed: $e\n$st');
      return null;
    }
  }
}
