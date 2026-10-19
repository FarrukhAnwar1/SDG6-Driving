# Validates passwords against bcrypt's 72-byte UTF-8 input limit.

"""The same bcrypt input limit applies to every password entry point."""

MAX_PASSWORD_BYTES = 72


def validate_password_byte_length(password: str) -> str:
    if len(password.encode("utf-8")) > MAX_PASSWORD_BYTES:
        raise ValueError("Password must be at most 72 UTF-8 bytes.")
    return password
