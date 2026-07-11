// Handles secure, on-device persistence of the JWT access token
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
}
