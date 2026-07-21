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

## Configure the speed limits database (PostGIS)

Speed limit data lives in a separate self hosted PostGIS database, loaded from OpenStreetMap road data via 'osm2pgsql'. Add these to the same '.env':

```
PG_HOST=...        # Host / IP
PG_PORT=5432       # Port
PG_NAME=...        # Database name 
PG_USER=...        # Username
PG_PASSWORD=...    # Password
```

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
  - `POST /change-password` (requires a valid access token, `Authorization: Bearer <token>`)
    with `{"current_password": "...", "new_password": "..."}` →
    `{"message": "Password changed successfully."}` on success.
    Use this when a logged-in user knows their current password and wants to
    set a new one; use `/forgot-password` + `/reset-password` instead when they
    can't log in at all. `new_password` must be at least 8 characters and
    different from `current_password`. `401` if `current_password` doesn't
    match the account's stored password.
  - `GET /speed-limit?lat=...&lng=...` (requires a valid access token,
    `Authorization: Bearer <token>`) → `{"speedLimitMph": 45.0, "roadName": "...", "distanceMeters": 5.9}`.
    Looks up the nearest tagged road segment to the given GPS point in the
    PostGIS `speedlimits` database, within a 75m search radius. Returns
    `{"speedLimitMph": null, "roadName": null, "distanceMeters": null}` if no
    tagged road is found nearby (e.g. off-road, out of the OSM extract's
    coverage area, or the nearest road has no `maxspeed` tag).

## Notes

- `app/models.py` mirrors the users table: `id, username, email, password_hash, created_at, email_verified,
  verification_token, verification_token_expires_at`.
- Speed limit lookups query `planet_osm_line` directly (no ORM model — raw
  SQL via SQLAlchemy's `text()`), since the geometry column needs PostGIS
  functions (`ST_Transform`, `ST_DWithin`) rather than plain ORM queries.
  Road geometry is stored in SRID 3857 (meters); incoming lat/lng (SRID 4326)
  is transformed before distance comparisons.
