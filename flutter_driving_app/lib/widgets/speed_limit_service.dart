// Placeholder for the backend Speed Limit API
class SpeedLimitService {
  SpeedLimitService._();

  static const List<double> _placeholderLimitsMph = [40];

  // Returns the posted speed limit (MPH) near the given coordinates.
  // TODO: Replace function body with a real Speed Limits API call,
  // such as by doing:
  //
  //   final response = await http.get(
  //     Uri.parse(
  //       '${ApiConfig.baseUrl}/speed-limit?lat=$latitude&lng=$longitude',
  //     ),
  //     headers: {'Authorization': 'Bearer $token'},
  //   );
  //   final data = jsonDecode(response.body);
  //   return (data['speedLimitMph'] as num?)?.toDouble();
  static Future<double?> fetchPostedSpeedLimitMph({
    required double latitude,
    required double longitude,
  }) async {
    await Future.delayed(const Duration(milliseconds: 250));

    final bucket = (latitude * 1000).round() ^ (longitude * 1000).round();
    return _placeholderLimitsMph[bucket.abs() % _placeholderLimitsMph.length];
  }
}
