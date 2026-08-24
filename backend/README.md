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

## The driving_reports table

This table exists in MySQL - `POST /driving-reports` writes to it,
no schema change needed. `app/models.py` mirrors it exactly:

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `int` | primary key, auto increment |
| `user_id` | `int` | taken from the bearer token, never from the request body |
| `overall_grade` | `decimal(5,2)` | |
| `speed_grade` | `decimal(5,2)` | the only dimension the app grades today |
| `braking_grade` | `decimal(5,2)` | not yet implemented, see below |
| `acceleration_grade` | `decimal(5,2)` | not yet implemented, see below |
| `turning_grade` | `decimal(5,2)` | not yet implemented, see below |
| `focus_grade` | `decimal(5,2)` | not yet implemented, see below |
| `report_date` | `datetime` | set to the trip's end time, not the insert time |
| `trip_duration_minutes` | `decimal(5,2)` | derived from the timestamps, caps at 999.99 |
| `trip_distance_miles` | `decimal(6,2)` | caps at 9999.99 |

Two things to check on the live table:

- **Is there a foreign key on `user_id`?** `DESCRIBE` shows the index but not
  constraints - run `SHOW CREATE TABLE driving_reports` to see. The code doesn't
  depend on one either way (SQLAlchemy deletes a user's reports itself, so
  `DELETE /users/me` cleans up regardless), but without an FK nothing stops an
  orphaned report if rows are ever deleted outside the API.
- **The four ungraded columns are `NOT NULL`.** The app can't compute braking,
  acceleration, turning or focus yet, so the API fills them with `100.00`. That
  is a placeholder standing in for "not measured", and it will look like real
  full marks to anything that reads or averages these columns later. Making the
  four columns nullable is the honest fix:
  ```sql
  ALTER TABLE driving_reports
      MODIFY braking_grade      decimal(5,2) NULL,
      MODIFY acceleration_grade decimal(5,2) NULL,
      MODIFY turning_grade      decimal(5,2) NULL,
      MODIFY focus_grade        decimal(5,2) NULL;
  ```
  If you run that, the API should send `NULL` for them instead of `100.00`.

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
  - `POST /driving-reports` (requires a valid access token,
    `Authorization: Bearer <token>`) saves one finished driving report for the
    authenticated user and returns it with its new `id`. The report is always
    attributed to the token's user, so the body carries no user id. Request:

    ```json
    {
      "startedAt": "2026-07-30T10:00:00",
      "endedAt": "2026-07-30T10:30:00",
      "tripDistanceMiles": 12.4,
      "overallGrade": 87.0,
      "speedGrade": 87.0
    }
    ```

    → `201` with the saved report:

    ```json
    {
      "id": 1, "overallGrade": 87.0, "speedGrade": 87.0,
      "brakingGrade": 100.0, "accelerationGrade": 100.0,
      "turningGrade": 100.0, "focusGrade": 100.0,
      "reportDate": "2026-07-30T10:30:00",
      "tripDurationMinutes": 30.0, "tripDistanceMiles": 12.4
    }
    ```

    `brakingGrade`, `accelerationGrade`, `turningGrade` and `focusGrade` are
    optional and default to `100.0`, since the app doesn't grade those dimensions
    yet. `tripDurationMinutes` is derived from the two
    timestamps rather than sent, so it can't disagree with them, and `reportDate`
    is set from `endedAt` so a report that uploads late still dates to the drive.

    `422` if `endedAt` is earlier than `startedAt`, if any grade is outside
    0–100, if the distance is negative or over 9999.99, if the trip is longer
    than 999.99 minutes (both would overflow their `decimal` columns), or if a
    required field is missing.

    Note the request has no home for `speedingOffenseCount` or
    `totalSpeedingDuration` — `driving_reports` has no columns for them, so the
    app computes them for the live dashboard but they are not saved. There is
    also no read endpoint yet: reports can be saved but not fetched back, so the
    driving report screen still renders from its in-memory `TripSummary`.

## Notes

- `app/models.py` mirrors the users table: `id, username, email, password_hash, created_at, email_verified,
  verification_token, verification_token_expires_at`.
- Speed limit lookups query `planet_osm_line` directly (no ORM model — raw
  SQL via SQLAlchemy's `text()`), since the geometry column needs PostGIS
  functions (`ST_Transform`, `ST_DWithin`) rather than plain ORM queries.
  Road geometry is stored in SRID 3857 (meters); incoming lat/lng (SRID 4326)
  is transformed before distance comparisons.
- Reports are graded on the client, not the server. `SpeedGradingService` in the
  Flutter app computes the grade live during the trip (the dashboard displays a
  running grade, so that computation has to happen there regardless), and
  `POST /driving-reports` stores those numbers verbatim. Grading server-side as
  well would mean two implementations of the same rules in two languages, which
  would eventually disagree and make the report screen contradict the dashboard.
- Only the finished report is saved, not the GPS samples behind it. Those are
  needed to produce the grade in the first place, which happens on the device,
  so there's nothing to keep afterward. 
- `overall_grade` is sent by the client rather than averaged from the other five
  columns server-side, keeping the client the single source of truth on grading.
  Today the app sets it equal to the speed grade (see the TODO at
  `live_dashboard_screen.dart:239`); when it becomes a weighted average of all
  five dimensions, no backend change is needed.
- Timestamps are stored as naive datetimes, matching the `datetime.utcnow()` used
  elsewhere in the API. The app sends local times with no UTC offset; anything
  tz-aware is converted to naive UTC on the way in, so the column never mixes
  the two.
