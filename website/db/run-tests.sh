#!/usr/bin/env bash
# Tests hg_dashboards.sql on a throwaway local Postgres that replays the production schema.
#   PROD_DB_REPO=/path/to/production-schema-repo PGHOST=/var/tmp/pg PGPORT=54329 ./website/db/run-tests.sh
# PROD_DB_REPO is the clone of the repository that owns the production migrations (it has db/test/run.sh).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
prod="${PROD_DB_REPO:?set PROD_DB_REPO to the clone that owns the production migrations}/db"
export PGUSER="${PGUSER:-postgres}"
psqlq() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
db=hg_dashboards_test
dropdb --if-exists "$db"; createdb "$db"
psqlq -d "$db" -f "$prod/test/supabase_stub.sql" >/dev/null
psqlq -o /dev/null -d "$db" -f "$prod/test/legacy_prod_fixture.sql"
# same order as the production runner: the catalogue v1 tests run before the 2026-10-20 migrations
v1() { for t in tests_common tests_app_compat tests_checkout tests_m4 tests_m5 tests_prod; do
         psqlq -o /dev/null -d "$db" -f "$prod/test/$t.sql"; done; }
done_v1=0
for m in "$prod/prod/supabase/migrations/"*.sql; do
  if [[ $done_v1 == 0 && $(basename "$m") > "20261020" ]]; then v1; done_v1=1; fi
  psqlq -o /dev/null -d "$db" -f "$m"
done
[[ $done_v1 == 0 ]] && v1
psqlq -o /dev/null -d "$db" -f "$prod/test/tests_v2.sql"
psqlq -o /dev/null -d "$db" -f "$here/hg_dashboards.sql"
psqlq -o /dev/null -d "$db" -f "$here/hg_dashboards.sql"        # running it twice must work
psqlq -o /dev/null -d "$db" -f "$here/test_hg_dashboards.sql"
psqlq -o /dev/null -d "$db" -f "$prod/test/tests_healthguardians.sql"   # the phone app's event log still works
echo "hg_dashboards: all tests passed"
