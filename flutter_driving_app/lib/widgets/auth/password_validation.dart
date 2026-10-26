// Checks password length in UTF-8 bytes to match the backend's bcrypt limit.

import 'dart:convert';

String? passwordByteLengthError(String password) =>
    utf8.encode(password).length > 72
    ? 'Password must be at most 72 UTF-8 bytes.'
    : null;
