// Creates mock access tokens for HTTP and account-isolation tests.

import 'dart:convert';

// Mock HTTP clients do not verify signatures. Keep real JWT claim shapes so
// tests also exercise account selection for encrypted local report storage.
String testAccessToken([int userId = 1]) {
  String encode(Map<String, dynamic> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': '$userId', 'purpose': 'access', 'exp': 4102444800})}.signature';
}
