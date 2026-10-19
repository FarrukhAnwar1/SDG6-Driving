# Completed trip uploads

Eligible trips are saved to the existing platform secure storage before upload.
Each completed trip has a random UUID, an account owner captured when starting
the drive, and a fixed request body. Grades and timestamps remain unchanged on
retry. The app allows returning Home after a successful local save; a storage
failure keeps the report open with Retry available.

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

# Sample continuity

Speed grading closes a streak at its last observed fix after a gap greater than
5 seconds. The next fix starts a fresh grace window. Smoothness grading closes
confirmed events at the last motion sample and discards candidates/filter history
after a gap greater than 250 milliseconds. Confirmed penalties are retained;
neither service charges for the missing interval. Exactly 5 seconds/250
milliseconds still counts as continuous sampling.
