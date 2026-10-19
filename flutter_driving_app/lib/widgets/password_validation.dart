import 'dart:convert';

String? passwordByteLengthError(String password) =>
    utf8.encode(password).length > 72
    ? 'Password must be at most 72 UTF-8 bytes.'
    : null;
