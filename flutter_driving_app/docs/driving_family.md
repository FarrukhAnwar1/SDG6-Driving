# Driving Family frontend

Home opens `DrivingFamilyScreen` with the ID and email from the existing
`GET /me` profile. The screen uses the existing JWT storage and `ApiConfig.baseUrl`.
All work is in the Flutter frontend; the family endpoints and email delivery
must still be implemented by the backend.

## Assumed API contract

Every request includes `Authorization: Bearer <token>`. POST bodies are JSON.
The proposed endpoints are used without a family name field because the
proposed database does not include a name.

| Action | Method and path | Body |
| --- | --- | --- |
| Load membership and summaries | `GET /families/me` | None |
| Create family | `POST /families` | `{}` |
| Join by emailed code | `POST /families/join` | `{"code":"opaque-code"}` |
| Invite by email (admin only) | `POST /families/me/invitations` | `{"email":"sam@example.com"}` |
| Leave family | `POST /families/leave` | `{}` |
| Remove another member | `DELETE /families/me/members/{userId}` | None |

Mutations accept successful 2xx responses and then reload membership and
summaries. No particular mutation response body is required. The invitation
endpoint is responsible for generating a code and sending the email; the
frontend never generates, hashes, or stores invitation codes. Each invitation
code is single-use and is bound to the invited email. Joining submits only the
code; the server obtains the account identity and email from authentication.

`GET /families/me` returns HTTP 200 with the following camelCase shape,
matching the existing driving report API's grade names and units:

```json
{
  "family": {
    "id": 7,
    "adminUserId": 1,
    "members": [
      {
        "userId": 1,
        "username": "Alex",
        "driveCount": 3,
        "averageGrades": {
          "overallGrade": 88,
          "speedGrade": 91.5,
          "brakingGrade": 82,
          "accelerationGrade": 85,
          "turningGrade": 94,
          "focusGrade": 96
        },
        "latestDrive": {
          "reportDate": "2026-10-05T14:30:00Z",
          "overallGrade": 93,
          "speedGrade": 95,
          "brakingGrade": 89,
          "accelerationGrade": 90,
          "turningGrade": 96,
          "focusGrade": 98
        },
        "totalDrivingMinutes": 90.5,
        "totalDistanceMiles": 45.6
      },
      {
        "userId": 2,
        "username": "Sam",
        "driveCount": 0,
        "averageGrades": null,
        "latestDrive": null,
        "totalDrivingMinutes": 0,
        "totalDistanceMiles": 0
      }
    ]
  }
}
```

The members list includes the admin and current user. IDs are integers. Grades
are percentages from 0 to 100; nullable grades display an em dash. The backend
calculates averages and totals across **all** saved reports and selects the
latest report by its end/report time. `reportDate` can be null for older reports.
Timestamps with no timezone offset are interpreted as UTC, as in Analytics.

No membership, including a removed member, returns HTTP 200
`{"family":null}` or HTTP 204. A generic HTTP 404 is an error, so an endpoint
that is not implemented cannot be mistaken for successful empty membership.

Errors may provide a user-facing `detail` or `message` string; FastAPI-style
validation detail lists are also supported. Structured error codes are described
below. HTTP 401 shows an expired-session message. Membership and permission
errors with HTTP 403, 404, or 409 trigger a membership reload. Email-mismatch
and invalid-code errors stay in the join form. A previously redeemed code is
reported as an invalid invitation because its database row has been deleted.

## Required database and API support

These are backend requirements for the frontend's invitation rules. No database
migrations or backend handlers are changed by this frontend implementation.

Keep an invitation row only until it is successfully redeemed. Enforce single
use by deleting that row in the same transaction that adds the user to the
family. Redemption-tracking columns are not required.

Add a unique index on `code_hash` to ensure each stored code identifies one
invitation and support lookup when the hash scheme permits deterministic lookup.

The proposed `family_invitations.email`, existing `users.email`, and proposed
`driving_families.admin_user_id` already supply recipient and admin information.
Use the same email normalization policy for invitation storage and account
comparison. Leaving or removal does not recreate a redeemed invitation;
rejoining requires a new invitation and code.

`POST /families/me/invitations` must:

1. Resolve the caller from the access token and their current family.
2. Verify the caller is that family's `admin_user_id`. Reject any other member
   before creating an invitation or sending an email.
3. Validate and normalize the recipient email, generate a secure random code,
   save the invitation with only the code's hash, and email the original code.
4. Set `invited_by_user_id` from the authenticated admin, never from request data.

`POST /families/join` must enforce both single use and email matching on the
server. A recommended transactional flow is:

1. Lock/reload the authenticated user and ensure they have no current family.
   All membership-changing handlers must coordinate updates to this same user
   row to prevent concurrent create/join operations from overwriting membership.
2. Locate and lock the existing invitation using the supplied code/hash; ensure
   its family still exists and the code is valid. A missing invitation returns
   `invalid_invitation`, including when the code was previously redeemed.
3. Compare the invitation's normalized email with the authenticated user's email.
   Do not trust an email submitted by the client. A mismatch must leave the
   invitation intact so its intended recipient can still join.
4. Set `users.family_id` and delete the matching `family_invitations` row in
   the same transaction. Roll back both changes on failure, restoring the
   invitation and leaving membership unchanged. Return success only after the
   transaction commits.

For this project's MySQL/SQLAlchemy stack, row locking such as `SELECT ... FOR
UPDATE` inside a transaction coordinates competing redemption requests. The
transaction must cover both membership and invitation deletion. See the official
[MySQL locking-read documentation](https://dev.mysql.com/doc/refman/8.0/en/innodb-locking-reads.html)
and [SQLAlchemy transaction documentation](https://docs.sqlalchemy.org/en/20/orm/session_transaction.html).

Use machine-readable errors so the frontend can distinguish correctable code
issues from changed membership or admin permissions:

| HTTP status | Error code | Frontend behavior |
| --- | --- | --- |
| 403 | `admin_required` | Close the stale invitation form and reload family permissions. |
| 403 | `invitation_email_mismatch` | Keep the join form open, show the signed-in email, and explain that the invited account is required. |
| 400 | `invalid_invitation` | The code is invalid, missing, or already redeemed. Keep the join form open so it can be corrected or replaced with a new invitation. |
| 409 | `already_in_family` | Reload membership rather than consuming another invitation. |
| 403 | `not_in_family` | Reload membership and remove stale controls. |

Deleting redeemed invitations means the server cannot distinguish a used code
from one that never existed. Return the same error and a combined message for
both cases, for example:

```json
{
  "detail": {
    "code": "invalid_invitation",
    "message": "This join code is invalid or has already been used. Check the code or ask the family admin for a new invitation."
  }
}
```

Top-level `code` and `message` fields are also supported. Recognized invitation
codes have fallback messages if `message` is omitted. Email-mismatch errors
should not disclose the invitation's intended email address. `GET /me` already
returns the signed-in email, so no invitation-preview endpoint is needed.

Backend validation should cover non-admin invitation attempts, correct-email
redemption with invitation deletion, wrong-email rejection without deletion,
rollback after a failed join, reuse after leaving or removal, and concurrent
redemption attempts. A code may produce at most one successful join. Code
expiration is a separate policy and is not required by these changes.

## UI behavior

- Without membership, Create Family opens an explanation and confirmation;
  Join Family opens a single-use code form that shows the signed-in email and
  explains that it must match the invited email. Codes are trimmed and retain their
  case and punctuation. Only blank codes and embedded whitespace are rejected
  locally because the backend code format has not been specified.
- Member cards show separate average and latest grades for Overall, Speed,
  Braking, Acceleration, Turning, and Focused Driving, plus time and distance.
  Drivers without reports show an empty score table and zero totals.
- Only the admin sees the invitation button, and opening the form is guarded
  by the loaded admin ID. Other members see an explanation of the restriction.
  Invitation copy explains that the recipient must sign in with the invited
  email and that the code can only be used once. The API must enforce these rules.
- Only the admin sees removal controls for other members. Leaving and removal
  require confirmation. An admin cannot leave while other members remain;
  the last admin is warned that leaving deletes the family.
- Initial loading, retries, pull-to-refresh, a refresh button, and refresh on
  app resume are supported. A failed refresh retains the last loaded summaries
  and disables actions until membership is refreshed successfully. Successful
  actions and membership loss show inline feedback.

Mocked HTTP tests cover these contracts and interactions. They do not send
emails or change real memberships.
