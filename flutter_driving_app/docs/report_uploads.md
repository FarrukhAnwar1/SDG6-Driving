# Completed trip uploads

Eligible trips are saved to the existing platform secure storage before upload.
Each completed trip has a random UUID, an account owner captured when starting
the drive, and a fixed request body. Grades and timestamps remain unchanged on
retry. The app allows returning Home after a successful local save; a storage
failure keeps the report open with Retry available.

## Driving modes in uploads

Settings offers Regular, Navigation and Pocket, saved under the `driving_mode`
secure-storage key as `regular`, `navigation` or `pocket`. An unrecognized stored
value loads as Regular. The mode is read when a drive starts and can only be
changed from Settings, which is opened from Home, so it cannot be switched during
a drive.

| Mode | `focusGrade` | `followingDistanceGrade` | Focus violations | Following violations |
| --- | --- | --- | --- | --- |
| Regular | Sent | Sent | Sent | Sent |
| Navigation | `null` | Sent | None | Sent |
| Pocket | `null` | `null` | None | None |

Both grade keys are always present in the body so the backend can tell "not
tracked" from "missing". A real score of 0 is sent as 0. The mode decides what is
sent, so stale grades or violations cannot leak into Navigation or Pocket
uploads. The body is built once, saved to the pending queue, then uploaded
unchanged: retries reuse the same payload and `clientTripId`. Saving a different
payload under an existing trip ID is rejected rather than overwriting it.

## Pending queues

Pending queues are separated by backend URL and account ID. Logging out retains
pending trips. A different account cannot upload them with its credentials.
Signing back into the original account lets Home retry them. Successful account
deletion clears that account's local queue.

Home retries pending reports after loading the signed-in profile and when Home
resumes. It also offers manual Retry for pending reports. Requests time out after
20 seconds. A failed batch stops and keeps its remaining reports for a later
attempt. Entries are removed only after a successful server response; a lost
response or failed local cleanup may cause another request, which the backend
deduplicates using the same trip ID. There is no OS background upload scheduler.

The shared database already has the report-upload schema update. For another
existing database, apply the missing schema additions before deploying the
updated backend/app; see [the backend README](../../backend/README.md#the-driving_reports-table).

Saved reports are read back with nullable `focusGrade` and
`followingDistanceGrade`. A missing `drivingMode` (older reports) is read as
Regular, and a missing following-distance grade is read as not tracked.

# Analytics

Analytics treats a null grade as "not tracked", never as zero. A real 0 is plotted
and averaged as 0.

- The Grade dropdown, chart line colors and Last Drive rows include Adequate
  Following Distance.
- Trips with no score for the selected category appear as gaps in the chart. A
  note says how many trips are missing, and a message replaces the chart when no
  selected trip tracked the category.
- Last Drive and each trip report show a "Not Tracked" row for every optional
  category that trip did not measure. Comparison averages skip null scores.
- Mode badges show Regular, Navigation or Pocket. Overall is compared only with
  earlier trips in the same driving mode, because each mode grades a different
  set of categories. Other categories compare across all earlier trips that
  tracked them. Trip, distance, time and average-grade totals include all three
  modes.

# Sample continuity

Speed grading closes a streak at its last observed fix after a gap greater than
5 seconds. The next fix starts a fresh grace window. Smoothness grading closes
confirmed events at the last motion sample and discards candidates/filter history
after a gap greater than 250 milliseconds. Confirmed penalties are retained;
neither service charges for the missing interval. Exactly 5 seconds/250
milliseconds still counts as continuous sampling.
