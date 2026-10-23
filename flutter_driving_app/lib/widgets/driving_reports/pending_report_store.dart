// Securely stores pending reports in separate queues for each backend and account.

import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../shared/api_config.dart';

// Report bodies stay encrypted in the existing platform secure storage. Keys
// include the API and account so a different login cannot inherit these trips.
class PendingReportStore {
  PendingReportStore._();
  static const _storage = FlutterSecureStorage();
  static Future<void>? _operations;

  static String _key(String userId) =>
      'pending_reports_v1_${Uri.encodeComponent(ApiConfig.baseUrl)}_$userId';

  static Future<T> _serialized<T>(Future<T> Function() operation) {
    final previous = _operations;
    final result = previous == null
        ? operation()
        : previous.then((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _operations = tail;
    return result.whenComplete(() {
      if (identical(_operations, tail)) _operations = null;
    });
  }

  static Future<List<Map<String, dynamic>>> _read(String userId) async {
    final value = await _storage.read(key: _key(userId));
    if (value == null) return [];
    final decoded = jsonDecode(value);
    if (decoded is! List) throw const FormatException('Invalid report queue');
    return decoded.map((item) {
      if (item is! Map<String, dynamic> || item['clientTripId'] is! String) {
        throw const FormatException('Invalid pending report');
      }
      return item;
    }).toList();
  }

  static Future<List<Map<String, dynamic>>> read(String userId) =>
      _serialized(() => _read(userId));

  static Future<void> put(String userId, Map<String, dynamic> payload) =>
      _serialized(() async {
        final reports = await _read(userId);
        for (final report in reports) {
          if (report['clientTripId'] == payload['clientTripId']) {
            if (jsonEncode(report) != jsonEncode(payload)) {
              throw StateError(
                'A saved trip cannot be replaced with different data',
              );
            }
            return;
          }
        }
        reports.add(payload);
        await _storage.write(key: _key(userId), value: jsonEncode(reports));
      });

  static Future<void> remove(String userId, String tripId) =>
      _serialized(() async {
        final reports = await _read(userId);
        reports.removeWhere((report) => report['clientTripId'] == tripId);
        if (reports.isEmpty) {
          await _storage.delete(key: _key(userId));
        } else {
          await _storage.write(key: _key(userId), value: jsonEncode(reports));
        }
      });

  static Future<void> clear(String userId) =>
      _serialized(() => _storage.delete(key: _key(userId)));
}
