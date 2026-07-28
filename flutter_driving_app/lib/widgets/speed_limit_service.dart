// Speed Limit API call service
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'api_config.dart';

class SpeedLimitService {
  SpeedLimitService._();

  // Returns the posted speed limit (MPH) near the given coordinates, or
  // null if none was found / the request failed
  //
  // Backend contract (see speed_limits.py):
  //   GET {baseUrl}/speed-limit?lat=<lat>&lng=<lng>
  //   -> { "speedLimitMph": number | null,
  //        "roadName": string | null,
  //        "distanceMeters": number | null }
  static Future<double?> fetchPostedSpeedLimitMph({
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
      return (data['speedLimitMph'] as num?)?.toDouble();
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
