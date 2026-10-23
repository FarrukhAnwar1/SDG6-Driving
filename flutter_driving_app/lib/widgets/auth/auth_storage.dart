// Handles secure, on-device persistence of the JWT access token
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthStorage {
  AuthStorage._();

  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'access_token';

  static Future<void> saveToken(String token) {
    return _storage.write(key: _tokenKey, value: token);
  }

  static Future<String?> readToken() {
    return _storage.read(key: _tokenKey);
  }

  static Future<void> deleteToken() {
    return _storage.delete(key: _tokenKey);
  }

  // This only selects an account's local upload queue. Authentication and JWT
  // signature/expiry checks remain exclusively on the backend.
  static String? userIdFromToken(String? token) {
    try {
      final parts = token?.split('.');
      if (parts == null || parts.length != 3) return null;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map<String, dynamic> || payload['sub'] is! String) {
        return null;
      }
      final id = int.tryParse(payload['sub'] as String);
      return id != null && id > 0 ? '$id' : null;
    } catch (_) {
      return null;
    }
  }
}
