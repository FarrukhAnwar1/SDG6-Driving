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

### Which roads count, and what they're worth

OSM tags every road *and every path* with `highway`, so the tag alone doesn't
mean a car can be there. The lookup is restricted to driveable classes
(`DRIVEABLE_HIGHWAY_TYPES` in `app/services/speed_limits.py`), which keeps it
off the ~773k footways, paths, cycleways, tracks, steps and corridors in this
extract, and off `construction`/`proposed` ways — 23.5% of which carry a
`maxspeed`, so they would otherwise match on roads that may not exist yet.
`service` (driveways, parking aisles, alleys) *is* included, so a driver in a
parking lot resolves to the aisle they're on rather than to an arterial 70m
away, but it carries no assumed limit and so reads as ungraded.

The query deliberately does **not** filter on `maxspeed`. Doing so returned the
nearest road that happened to be tagged on an untagged residential street,
that meant answering with an arterial's 45 from up to 75m away, under that
arterial's name. `GET /speed-limit` and the violation road-name lookup now
search the same radius and the same classes, which is what makes a stored
violation name the road whose limit the driver was actually graded against.

#### Assumed limits

`maxspeed` coverage in this extract is good exactly where it matters least and
poor where it matters most:

| Road group | Ways | Tagged |
| --- | --- | --- |
| Arterials (`motorway`, `trunk`, `primary`, `secondary`) | 155,424 | **80.3%** |
| Local streets (`residential`, `tertiary`, `unclassified`, `living_street`) | 685,066 | **11.3%** |
| Ramps (`*_link`) | 36,778 | **4.8%** |
| `service` | 1,181,540 | **0.5%** |

`residential` alone is 584k ways at 8.6%, so without a fallback the grader says
nothing about neighbourhood driving — which is where a 25 mph limit exists and
where speeding is most dangerous.

A class gets an assumed limit only when its tagged ways cluster tightly enough
that one number describes it. Each tolerance is derived, not picked: wide enough
that a driver doing the real limit on the highest plausible posting for that
class still doesn't register as speeding.

| `highway` | Assumed | Tolerance | Basis |
| --- | --- | --- | --- |
| `residential` | 25 mph | 10 mph | 68.4% of 50,546 tagged ways; 30 is the ceiling (25+30 = 79.7%). Matches PA's statutory 25 mph urban-district limit |
| `unclassified` | 25 mph | 15 mph | 35.9% of 2,794 — weaker mode with a 35 mph tail |
| `living_street` | 15 mph | 10 mph | 88 tagged ways, spread 5–25; only 1,240 ways in the extract |

Deliberately absent: `tertiary` (30/35/40/45 at 33/25/13/12% — assume 30 and a
driver legally doing 50 on a real 45 reads as 20 over), `secondary` (same flat
shape, already 58% tagged), `service` (grading driveways isn't the point),
`*_link` (ramps vary far too much), and the arterials (already 90%+ tagged, so
an untagged one is an outlier rather than a gap).

`maxspeed=unposted` (392 ways) resolves to the assumed limit rather than to
nothing, since that tag is stating the statutory default applies.

Between `"NN mph"`, a bare number and `"NN km/h"`, the parser covers all but 31
of the extract's 210,340 tagged ways, so there is no long tail of tag formats
left to handle.

#### Turning assumptions on

Assumed limits are **off by default** (`SPEED_LIMIT_INFERENCE_ENABLED=false`).
The app grades every limit at a flat 5 mph tolerance and does not yet read
`speedingThresholdMph`, so an assumed 25 would flag a driver legally doing 30 on
a residential street actually posted 30. Once the app honours that field, set:

```dotenv
SPEED_LIMIT_INFERENCE_ENABLED=true
```

Expect a step change in violation counts when you do — trips through
neighbourhoods that previously graded clean will start producing violations,
because ~91% of residential streets were being skipped rather than driven well.
The numbers in the tables above came from the extract itself:

```sql
-- coverage by road class
SELECT highway, count(*) AS ways,
       count(*) FILTER (WHERE tags -> 'maxspeed' IS NOT NULL) AS with_maxspeed
FROM planet_osm_line WHERE highway IS NOT NULL GROUP BY highway ORDER BY ways DESC;

-- the modal posting per class, which is where the assumed limits come from
SELECT * FROM (
  SELECT highway, tags -> 'maxspeed' AS maxspeed, count(*) AS ways,
         row_number() OVER (PARTITION BY highway ORDER BY count(*) DESC) AS rn
  FROM planet_osm_line
  WHERE highway IN ('residential','unclassified','living_street','tertiary','service')
    AND tags -> 'maxspeed' IS NOT NULL
  GROUP BY highway, 2
) t WHERE rn <= 5 ORDER BY highway, rn;
```

Rerun them after an extract rebuild. If coverage or the modes have shifted,
the table in `app/services/speed_limits.py` should shift with them.

## Configure advanced driving feedback (Gemini)

`GET /advanced-suggestion` uses the Gemini Developer API through `google-genai`.
Create an API key in [Google AI Studio](https://aistudio.google.com/apikey) and add
these settings to `.env`:

```dotenv
GEMINI_API_KEY=your-gemini-api-key
GEMINI_MODEL=gemini-3.5-flash-lite
GEMINI_TIMEOUT_SECONDS=30
```

The default model supports structured JSON responses and currently offers free
tier input/output, subject to your project's quota and availability. Use a free
tier project if you want free usage; selecting this model does not override a
project's billing tier. Check Google's [pricing](https://ai.google.dev/gemini-api/docs/pricing#gemini-3.5-flash-lite)
and [rate limits](https://ai.google.dev/gemini-api/docs/rate-limits) for current
details. The model can be changed through `GEMINI_MODEL` without editing code.

The key stays on the server. The prompt contains the selected reports and all
their violation details, including road names and timestamps, plus calculated
trends. It excludes account IDs, usernames, email addresses, and bearer tokens.
Google lists free tier inputs/outputs as used to improve its products; see the
[Gemini pricing and data-use table](https://ai.google.dev/gemini-api/docs/pricing#gemini-3.5-flash-lite).

The application starts without a Gemini key. An eligible feedback request then
returns `503`; insufficient history returns its normal `200` response without
contacting Gemini. The timeout defaults to 30 seconds and accepts values greater
than zero and up to 120 seconds. Each eligible request makes one generation
attempt, with no automatic retries or model fallback. Feedback is generated on
demand, not saved or cached, and responses include `Cache-Control: no-store`.
Have the frontend fetch when needed rather than polling, since each successful
generation consumes quota.

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

## The violations table

Where and when a trip went wrong, so a saved report can show the specific
moments behind its grade instead of just a number. One row per violation,
mirrored by `Violation` in `app/models.py`:

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `int` | primary key, auto increment |
| `user_id` | `int` | FK → `users.id` (`ON DELETE CASCADE`), denormalized from the parent report |
| `driving_report_id` | `int` | FK → `driving_reports.id` (`ON DELETE CASCADE`) |
| `violation_type` | `enum` | `Proper Speed`, `Smooth Braking`, `Smooth Accelerating`, `Smooth Turning`, `Focused Driving` |
| `road_name` | `varchar(255)` | nullable — the speed-limit lookup returns no name off-road or outside the OSM extract |
| `start_time` | `datetime` | |
| `end_time` | `datetime` | `CHECK (end_time >= start_time)` |

`user_id` duplicates what the parent report already knows, which makes "every
violation this user has ever had" one indexed lookup rather than a join.

The `violation_type` labels are spelled out in `VIOLATION_TYPES` in
`schemas.py`, matching the `ENUM` exactly — anything else fails at `INSERT`, so
the API validates against that set rather than letting the driver find out from
a 500.

`POST /driving-reports` writes these rows, from the `violations` array on the
upload. There is no separate violations endpoint: a violation only means
anything as part of the trip it happened on, and writing both in one request
keeps a report from ever existing without the violations behind it.

### Coordinates in, road names out

`TripSummary`'s violations carry the lat/lng where each one began; the table has
a road name and no geometry. The endpoint bridges that gap: every point on an
upload is resolved against the same PostGIS road data behind `GET /speed-limit`
(nearest named `highway` within 75m), and the coordinates are then dropped.
`app/services/road_names.py` does this for the whole report in one query rather
than one per violation.

`road_name` is `NULL` when the point is off-road, outside the OSM extract's
coverage, or the nearest road is unnamed and also when the PostGIS database is
unreachable. That last case is deliberate: the road data is a *different*
database from the one the report is being written to, and losing a road name is
recoverable while losing the drive is not, so the upload still returns `201`
with the violations saved unnamed. The failure is logged as a warning.

### Which label each grading service maps to

The client sends the `ENUM` label directly. The backend does not infer it from
the violation's shape. `TripSummary` keeps four lists, and they map like this:

| `TripSummary` field | `violation_type` |
| --- | --- |
| `speedingViolations` | `Proper Speed` |
| `brakingViolations` | `Smooth Braking` |
| `acceleratingViolations` | `Smooth Accelerating` |
| `turningViolations` | `Smooth Turning` |
| `focusedDrivingViolations` | `Focused Driving` |

Everything else the grading services attach to a violation. `speedLimitMph`
and `peakSpeedMph` on a speeding streak, `peakGForce` on a smoothness
violation, `speedAtStartMph` on a focus violation which has no column. Those fields
are **ignored rather than rejected**, so the client can send a whole violation
object unchanged, but they are not stored and can't be read back.

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
    `Authorization: Bearer <token>`) →

    ```json
    {
      "speedLimitMph": 45.0, "roadName": "...", "distanceMeters": 5.9,
      "speedLimitSource": "posted", "speedingThresholdMph": 5.0
    }
    ```

    Looks up the nearest **driveable** road segment to the given GPS point in
    the PostGIS `speedlimits` database, within a 75m search radius, then
    decides what limit applies to it. See *Which roads count, and what they're
    worth* below. `speedLimitMph` is `null` when no driveable road is nearby
    (off-road, or outside the extract's coverage) or when the nearest one
    carries no limit worth using. `roadName` and `distanceMeters` are still
    filled in that second case, so the app can name the road while grading
    nothing against it.

    `speedLimitSource` is `"posted"` (read off the road's `maxspeed` tag),
    `"inferred"` (assumed from the road's class) or `"unknown"` (no limit).
    `speedingThresholdMph` is how far over the limit counts as speeding on this
    road, and is `null` exactly when the limit is. It is sent by the server
    rather than fixed in the app because an assumed limit needs more slack than
    a posted one, and how much depends on the road class.
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
      "speedGrade": 87.0,
      "violations": [
        {
          "violationType": "Proper Speed",
          "startTime": "2026-07-30T10:05:00",
          "endTime": "2026-07-30T10:05:18",
          "latitude": 40.0379,
          "longitude": -75.0182
        }
      ]
    }
    ```

    -> `201` with the saved report, each violation carrying the road name the
    server resolved its coordinates to:

    ```json
    {
      "id": 1, "overallGrade": 87.0, "speedGrade": 87.0,
      "brakingGrade": 100.0, "accelerationGrade": 100.0,
      "turningGrade": 100.0, "focusGrade": 100.0,
      "reportDate": "2026-07-30T10:30:00",
      "tripDurationMinutes": 30.0, "tripDistanceMiles": 12.4,
      "violations": [
        {
          "id": 1, "violationType": "Proper Speed", "roadName": "Roosevelt Blvd",
          "startTime": "2026-07-30T10:05:00", "endTime": "2026-07-30T10:05:18"
        }
      ]
    }
    ```

    `brakingGrade`, `accelerationGrade`, `turningGrade` and `focusGrade` are
    optional and default to `100.0`, since the app doesn't grade those dimensions
    yet. `tripDurationMinutes` is derived from the two
    timestamps rather than sent, so it can't disagree with them, and `reportDate`
    is set from `endedAt` so a report that uploads late still dates to the drive.

    `violations` is optional and defaults to `[]`, so a client that sends only
    grades keeps working unchanged, and a clean trip legitimately has none. Each
    violation needs `violationType` (one of the five `ENUM` labels),
    `startTime`, `endTime`, `latitude` and `longitude`. The coordinates become
    `road_name` and are not stored. See the `violations` table section above
    for the mapping and what happens to the extra grading fields.

    The report and its violations are written in one transaction, so a trip
    never lands with half its violations attached.

    `422` if `endedAt` is earlier than `startedAt`, if any grade is outside
    0–100, if the distance is negative or over 9999.99, if the trip is longer
    than 999.99 minutes (both would overflow their `decimal` columns), or if a
    required field is missing. Also `422` if a violation's `violationType` isn't
    one of the five labels (it would fail the `ENUM` at `INSERT`), if its
    `endTime` is earlier than its `startTime` (it would fail
    `CHECK (end_time >= start_time)`), if a coordinate is out of range, or if
    more than 500 violations are sent in one report.

    Note the request has no home for `speedingOffenseCount` or
    `totalSpeedingDuration` — `driving_reports` has no columns for them, so the
    app computes them for the live dashboard but they are not saved. Both are
    now derivable from the stored violations anyway.
  - `GET /driving-reports?limit=n` (requires a valid access token,
    `Authorization: Bearer <token>`) returns the authenticated user's `n` most
    recent reports, newest trip first, each with the violations recorded during
    that trip:

    ```json
    {
      "reports": [
        {
          "id": 12, "overallGrade": 87.0, "speedGrade": 87.0,
          "brakingGrade": 90.0, "accelerationGrade": 92.0,
          "turningGrade": 88.0, "focusGrade": 95.0,
          "reportDate": "2026-07-30T10:30:00",
          "tripDurationMinutes": 30.0, "tripDistanceMiles": 12.4,
          "violations": [
            {
              "id": 3,
              "violationType": "Proper Speed",
              "roadName": "Roosevelt Blvd",
              "startTime": "2026-07-30T10:05:00",
              "endTime": "2026-07-30T10:05:18"
            }
          ]
        }
      ]
    }
    ```

    `limit` is optional and defaults to 10, capped at 100 — without a cap one
    request could pull an entire history, and every violation under it, into
    memory. `422` if it's below 1 or above 100.

    Ordering is by `report_date` (the trip's end time) descending, so it reflects
    when people drove rather than when the uploads landed, with `id` breaking
    ties between trips that ended in the same second.

    Violations within a report are ordered by `start_time`, and carry no
    `userId` or `drivingReportId`: the report is already the caller's own and
    already identifies itself. The results are scoped to the token's user, so one
    account can't read another's history.

## Advanced driving suggestion

`GET /advanced-suggestion` requires `Authorization: Bearer <token>` and takes no
body or query parameters. The driver is always identified from the token.

```bash
curl http://localhost:8000/advanced-suggestion \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN"
```

Example `200` response (the message varies with the driver's history):

```json
{
  "status": "ready",
  "message": "Your speed grades have steadily improved over the past month, showing that your attention is paying off. Braking grades remain your lowest area across recent weeks, so try leaving more following distance to give yourself time to slow down smoothly.",
  "reportsAnalyzed": 42,
  "analysisStartDate": "2026-07-01T10:30:00",
  "analysisEndDate": "2026-08-15T18:00:00"
}
```

Display `message` as plain text. It blends one motivational observation with one
actionable piece of constructive feedback in a single natural paragraph, usually
2-4 sentences. The backend validates the generated JSON and requires a nonempty
message of at most 1200 characters. The status, count, and dates are calculated
by the backend, not generated by Gemini.

The endpoint shares the database query behind `GET /driving-reports`, loading
the user's latest **100 reports** and their violations. It sends the same report
fields to Gemini in chronological order, including **every grade**, trip date,
distance and duration, and each violation's type, road name, and start/end time.
All read values are treated as accurate. Road names provide optional context:
the prompt only asks Gemini to mention one if a recurring pattern there makes
the feedback more useful. A road name is never required in the message.

To support analysis over time, the backend also calculates:

- Weekly averages for all six grades, with weeks beginning Monday and each trip
  weighted equally. Weeks with no reports are omitted.
- Earlier and recent period summaries, splitting the observed time span at its
  midpoint. Grade changes are recent minus earlier averages, in grade points.
- Violation counts and total durations for every violation type, including
  counts per driving hour and violation minutes per driving hour in each period.
  Rate changes account for differing amounts of driving. Rates are `null` when
  driving duration is zero; violation durations can overlap.

Long-term feedback requires **at least six dated reports spanning 28 days**
within the selected 100 reports. The returned date range describes that sample,
which may not cover the driver's entire history. Undated reports are included
in the report count, overall statistics, and full prompt data, but excluded from
weekly comparisons and the six-dated-report requirement. The endpoint uses the
report dates as stored, consistent with the existing report API.

With no reports, the endpoint returns `200` without calling Gemini:

```json
{
  "status": "insufficient_history",
  "message": "Start building your driving history by saving your trips. Once you have at least 6 dated trips spanning 28 days, you'll receive feedback on your progress and what to work on.",
  "reportsAnalyzed": 0,
  "analysisStartDate": null,
  "analysisEndDate": null
}
```

A short history uses the same shape, with its actual count/date range and a
brief message encouraging continued trip recording. Dates are `null` if no
selected reports have dates.

Errors use FastAPI's `{"detail": "..."}` format, and never substitute invented
feedback for a failed generation:

| Status | Meaning |
| --- | --- |
| `401` / `403` | Missing, invalid, or expired authentication; missing-token status depends on FastAPI version |
| `429` | Gemini quota exhausted; retry later |
| `502` | Gemini rejected the generation request or returned malformed, empty, blocked, or truncated feedback |
| `503` | Missing/invalid Gemini configuration, unavailable model, connection failure, or provider outage |
| `504` | Gemini request timed out |

## Tests

Install the current requirements after recreating the virtual environment:

```bash
python -m pip install -r requirements.txt
python -m pytest tests -q -p no:cacheprovider
```

`requirements.txt` temporarily constrains AnyIO to `>=4.14.1,<4.15` because
Starlette 1.6.0's test client references a `BlockingPortal` alias deprecated in
AnyIO 4.15. Remove this constraint after upgrading to a Starlette release that
includes [the upstream fix](https://github.com/Kludex/starlette/pull/3498), then
verify with `python -m pytest tests -q -p no:cacheprovider -W error`.

The speed-limit tests stub the PostGIS query, since it needs a live database,
and check the decision made on top of a row: which tag values parse, which road
classes carry an assumed limit and which deliberately don't, and that an
assumption never reaches the client labelled as a posted sign. They also assert
the two nearest road queries still filter on the same classes, since those
drifting apart is what let a violation name a road the driver was never graded
against.

The suggestion tests use an in-memory SQLite database and a mocked HTTP transport
for the real Gemini SDK. They cover authentication, user isolation, the report
limit and ordering, full prompt data, trend calculations, insufficient history,
and provider errors without a live MySQL/PostGIS server or Gemini key.

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
  so there's nothing to keep afterward. The one exception is the coordinates a
  violation started at, and those aren't kept either, they're resolved to a
  road name on the way in and dropped, so the stored history says which road a
  violation happened on without amounting to a trace of where the driver went.
- Road names are resolved at upload time rather than on read. A name is a fact
  about the moment the violation happened, and the OSM extract gets rebuilt; a
  report shouldn't quietly change its mind about where a drive went wrong
  because the map data moved underneath it.
- `GET /driving-reports` pulls each report's violations with `selectinload`, so a
  page of reports costs one extra query for all of their violations rather than
  one query per report as the response model walks the rows.
- `overall_grade` is sent by the client rather than averaged from the other five
  columns server-side, keeping the client the single source of truth on grading.
  Today the app sets it equal to the speed grade (see the TODO at
  `live_dashboard_screen.dart:239`); when it becomes a weighted average of all
  five dimensions, no backend change is needed.
- Timestamps are stored as naive datetimes, matching the `datetime.utcnow()` used
  elsewhere in the API. The app sends local times with no UTC offset; anything
  tz-aware is converted to naive UTC on the way in, so the column never mixes
  the two.
