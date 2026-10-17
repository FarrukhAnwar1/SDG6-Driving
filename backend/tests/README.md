# Backend regression tests

From `backend`, run:

```powershell
.venv/Scripts/python.exe -m pytest tests -q -p no:cacheprovider
```

The family API tests use SQLite with foreign keys enabled and mock invitation
email delivery. They exercise all six endpoints, authorization, member statistics,
single-use codes, sibling invitation revocation, leave/removal restrictions,
transaction rollback, and retries without duplicate email.

Six additional tests require MySQL 8 and exercise actual InnoDB locks and
`REPEATABLE READ` snapshots. These cover joins after authentication, joins during
family deletion, simultaneous removal/leaving, concurrent redemption, competing
create/join requests, and attempts to join two different families concurrently.

Set `FAMILY_TEST_MYSQL_URL` to an **empty, disposable local database** whose name
starts with `sdg6_family_test_`, then run the same family test file:

```powershell
$env:FAMILY_TEST_MYSQL_URL = 'mysql+pymysql://root:local-test-password@127.0.0.1:3307/sdg6_family_test_local'
.venv/Scripts/python.exe -m pytest tests/test_families.py -q -p no:cacheprovider
Remove-Item Env:FAMILY_TEST_MYSQL_URL
```

The fixture creates and drops application tables in that database for each test.
It rejects nonlocal hosts, names without the test prefix, and databases that
already contain tables. It never uses the application's configured database URL.
Without this variable, the six MySQL tests are skipped.
