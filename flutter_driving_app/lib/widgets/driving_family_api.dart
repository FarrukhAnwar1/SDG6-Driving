// API for interacting with the Driving Family service
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_config.dart';
import 'auth_storage.dart';
import 'driving_family_summary.dart';

class DrivingFamilyException implements Exception {
  const DrivingFamilyException(this.message, {this.statusCode, this.errorCode});

  final String message;
  final int? statusCode;
  final String? errorCode;

  // Membership or permissions might have changed while a form was open
  bool get shouldRefresh =>
      !const {
        'invitation_already_used',
        'invitation_email_mismatch',
        'invalid_invitation',
      }.contains(errorCode) &&
      const [403, 404, 409].contains(statusCode);
}

class DrivingFamilyApi {
  DrivingFamilyApi._();

  static Future<DrivingFamilySummary?> fetchCurrent() async {
    final response = await _request('GET', '/families/me');
    if (response.statusCode == 204) return null;
    _checkResponse(response, 'Could not load your Driving Family.');
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || !decoded.containsKey('family')) {
        throw const FormatException('Missing family response.');
      }
      if (decoded['family'] == null) return null;
      return DrivingFamilySummary.fromJson(
        decoded['family'] as Map<String, dynamic>,
      );
    } catch (_) {
      throw const DrivingFamilyException(
        'Could not read your Driving Family. Please try again.',
      );
    }
  }

  static Future<void> create() => _mutate(
    'POST',
    '/families',
    'Could not create a family. Please try again.',
  );

  static Future<void> join(String code) => _mutate(
    'POST',
    '/families/join',
    'Could not join this family. Check your code and try again.',
    body: {'code': code.trim()},
  );

  static Future<void> invite(String email) => _mutate(
    'POST',
    '/families/me/invitations',
    'Could not send the invitation. Please try again.',
    body: {'email': email.trim()},
  );

  static Future<void> leave() => _mutate(
    'POST',
    '/families/leave',
    'Could not leave the family. Please try again.',
  );

  static Future<void> removeMember(int userId) => _mutate(
    'DELETE',
    '/families/me/members/$userId',
    'Could not remove this member. Please try again.',
  );

  static Future<void> _mutate(
    String method,
    String path,
    String fallback, {
    Map<String, String>? body,
  }) async {
    final response = await _request(method, path, body: body);
    _checkResponse(response, fallback);
  }

  static Future<http.Response> _request(
    String method,
    String path, {
    Map<String, String>? body,
  }) async {
    try {
      final token = await AuthStorage.readToken();
      if (token == null || token.isEmpty) {
        throw const DrivingFamilyException(
          'Please log in to view your Driving Family.',
        );
      }
      final uri = Uri.parse('${ApiConfig.baseUrl}$path');
      final headers = {
        'Authorization': 'Bearer $token',
        if (method == 'POST') 'Content-Type': 'application/json',
      };
      final request = switch (method) {
        'GET' => http.get(uri, headers: headers),
        'POST' => http.post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? {}),
        ),
        'DELETE' => http.delete(uri, headers: headers),
        _ => throw ArgumentError('Unsupported method: $method'),
      };
      return await request.timeout(const Duration(seconds: 20));
    } on DrivingFamilyException {
      rethrow;
    } on TimeoutException {
      throw const DrivingFamilyException(
        'The request timed out. Please try again.',
      );
    } catch (_) {
      throw const DrivingFamilyException(
        'Could not connect. Check your connection and try again.',
      );
    }
  }

  static void _checkResponse(http.Response response, String fallback) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final error = _serverError(response);
    final invitationMessage = switch (error.code) {
      'invitation_already_used' =>
        'This join code has already been used. Ask the family admin for a new invitation.',
      'invitation_email_mismatch' =>
        'This invitation was sent to a different email address. Sign in with the account that received it.',
      'invalid_invitation' =>
        'This join code is invalid. Check the code or ask the family admin for a new invitation.',
      'admin_required' => 'Only the family admin can send invitations.',
      _ => null,
    };
    final message = switch (response.statusCode) {
      401 => 'Session expired. Please log in again.',
      // A missing endpoint must not appear to be a successful no-family state
      404 =>
        error.message ??
            invitationMessage ??
            'Driving Family is unavailable. Please try again later.',
      403 =>
        error.message ??
            invitationMessage ??
            'You no longer have permission to do this. Refresh your family and try again.',
      409 =>
        error.message ??
            invitationMessage ??
            'Your family membership changed. Refresh and try again.',
      429 => 'Too many requests. Please wait a moment and try again.',
      >= 500 => fallback,
      _ => error.message ?? invitationMessage ?? fallback,
    };
    throw DrivingFamilyException(
      message,
      statusCode: response.statusCode,
      errorCode: error.code,
    );
  }

  static ({String? code, String? message}) _serverError(
    http.Response response,
  ) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return (code: null, message: null);
      final detail = decoded['detail'] ?? decoded['message'];
      final codeValue = detail is Map<String, dynamic>
          ? detail['code'] ?? decoded['code']
          : decoded['code'];
      final code = codeValue is String ? codeValue : null;
      final message = detail is Map<String, dynamic>
          ? detail['message'] ?? decoded['message']
          : detail;
      if (message is String &&
          message.trim().isNotEmpty &&
          message != 'Not Found') {
        return (code: code, message: message);
      }
      // FastAPI uses a list for request validation errors
      if (detail is List) {
        final messages = detail
            .whereType<Map<String, dynamic>>()
            .map((item) => item['msg'])
            .whereType<String>()
            .toList();
        if (messages.isNotEmpty) {
          return (code: code, message: messages.join('\n'));
        }
      }
      return (code: code, message: null);
    } catch (_) {
      // An HTML or empty error response still gets a useful fallback
    }
    return (code: null, message: null);
  }
}
