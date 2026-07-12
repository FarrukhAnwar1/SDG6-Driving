# SDG6 Driving — Backend

FastAPI backend connected to a MySQL database.

## Setup

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

## Configure the database

Copy the template and fill in your real MySQL credentials:

```bash
cp .env.example .env
```

Then edit `.env`:

```
DB_HOST=...        # Host / IP
DB_PORT=3306       # Port
DB_NAME=...        # Database name
DB_USER=...        # Username
DB_PASSWORD=...    # Password
```

`.env` is git-ignored — it never gets committed.

## Run

```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

- Endpoints (backed by MySQL):
  - `GET  /users` → `{"users": [{"id": 1, "username": "...", "email": "...", "created_at": "...", "email_verified": false}]}`
  - `POST /users` with `{"username": "...", "email": "...", "password": "..."}` →
    the created user (same shape as above). The password is hashed with bcrypt
    into `password_hash`; the raw password and verification tokens are never returned.
  - `409` if the `username` or `email` already exists (both are `UNIQUE`).
  - `POST /forgot-password` with `{"email": "..."}` → always
    `{"message": "If the email is registered, a password reset code has been sent."}`
    (same response whether or not the email exists, to avoid leaking which emails
    are registered). If the account exists, emails a 6-digit code valid for
    `PASSWORD_RESET_CODE_EXPIRE_MINUTES` (default 15).
  - `POST /reset-password` with `{"email": "...", "code": "...", "new_password": "..."}` →
    `{"message": "Password reset successfully."}` on success.
    `400` if the code is missing, wrong, or expired. `429` after
    `PASSWORD_RESET_MAX_ATTEMPTS` (default 5) wrong codes, until a new code is requested.

## Notes

- `app/models.py` mirrors the users table: `id, username, email, password_hash, created_at, email_verified,
  verification_token, verification_token_expires_at`.
