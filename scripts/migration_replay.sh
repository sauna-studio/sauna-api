#!/usr/bin/env bash
set -euo pipefail
umask 077

run_dir=${1:?A freshly owned disposable directory is required}
[[ $(id -un) == postgres && $run_dir =~ ^/tmp/sauna-migration-run\.[A-Za-z0-9]+$ ]]
[[ ! -L $run_dir && $(readlink -f "$run_dir") == "$run_dir" ]]
for variable in $(compgen -v); do
    case "$variable" in PG*|ATLAS*) unset "$variable" ;; esac
done
[[ $(stat -c %u "$run_dir") == "$(id -u)" && $(stat -c %a "$run_dir") == 700 ]]
[[ $(postgres --version) == 'postgres (PostgreSQL) 18.'* ]]

cluster="$run_dir/cluster"
socket="$run_dir/socket"
mkdir -m 700 "$socket"
initdb --pgdata="$cluster" --username=postgres --auth-local=peer --auth-host=reject > "$run_dir/init.log" 2>&1
# Peer retains kernel identity checks. These exact mappings exercise SQL role
# separation; they do not pretend that one OS user becomes multiple isolated users.
printf 'sauna_ci postgres sauna_admin\nsauna_ci postgres sauna_app\nsauna_audit postgres sauna_audit_reviewer\n' > "$cluster/pg_ident.conf"
printf 'local sauna_audit_sandbox sauna_audit_reviewer peer map=sauna_audit\nlocal all sauna_audit_reviewer reject\nlocal all all peer map=sauna_ci\nhost all all 0.0.0.0/0 reject\nhost all all ::0/0 reject\n' > "$cluster/pg_hba.conf"
# The bootstrap superuser is needed only to create this disposable cluster's roles.
sed -i '1i local all postgres peer' "$cluster/pg_hba.conf"
started=0
cleanup() {
    if [[ $started == 1 ]]; then pg_ctl --pgdata="$cluster" --mode=immediate --wait stop > /dev/null 2>&1; fi
}
trap cleanup EXIT
pg_ctl --pgdata="$cluster" --log="$run_dir/server.log" --options="-c listen_addresses='' -c unix_socket_directories='$socket' -c unix_socket_permissions=0700 -c log_statement=none" --wait start > /dev/null
started=1
psql_cmd() {
    psql --no-password --no-psqlrc --host="$socket" --username="$1" --dbname="$2" --set=ON_ERROR_STOP=1 --tuples-only --no-align "${@:3}"
}
psql_cmd postgres postgres <<'SQL' > /dev/null
CREATE ROLE sauna_admin LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE sauna_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE sauna_audit_reviewer LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE DATABASE sauna_atlas_replay OWNER sauna_admin;
CREATE DATABASE sauna_ci_dev OWNER sauna_admin;
CREATE DATABASE sauna_audit_sandbox OWNER sauna_admin;
SQL
[[ $(psql_cmd postgres postgres -c 'SHOW listen_addresses') == '' ]]
[[ $(psql_cmd sauna_app sauna_atlas_replay -c "SELECT session_user=current_user AND session_user='sauna_app'") == t ]]
# Extension lifecycle is separate from Atlas CE; see tracking Issue64. Never
# accept arbitrary candidate SQL for bootstrap-superuser execution.
bootstrap_sql=$(cat "$run_dir/prerequisites-bootstrap.sql")
verify_sql=$(cat "$run_dir/prerequisites-verify.sql")
for database in sauna_atlas_replay sauna_ci_dev sauna_audit_sandbox; do
    psql_cmd postgres "$database" --command="SET statement_timeout='10s';
$bootstrap_sql" > "$run_dir/prerequisites.log" 2>&1
    [[ $(psql_cmd sauna_admin "$database" --command="$verify_sql") == 1 ]]
done
# These negative states exist only in this fresh, credential-free cluster.
psql_cmd postgres postgres -c 'CREATE DATABASE sauna_ci_prereq_probe OWNER sauna_admin' > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 0 ]]
psql_cmd postgres sauna_ci_prereq_probe -c "CREATE SCHEMA extensions AUTHORIZATION postgres; CREATE EXTENSION btree_gist WITH SCHEMA extensions VERSION '1.7'; GRANT USAGE ON SCHEMA extensions TO sauna_admin,sauna_app;" > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 0 ]]
psql_cmd postgres sauna_ci_prereq_probe -c 'DROP EXTENSION btree_gist; DROP SCHEMA extensions;' > /dev/null
psql_cmd postgres sauna_ci_prereq_probe --command="SET statement_timeout='10s';
$bootstrap_sql" > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 1 ]]
psql_cmd postgres sauna_ci_prereq_probe -c 'ALTER SCHEMA extensions RENAME TO sauna_unexpected_extensions' > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 0 ]]
psql_cmd postgres sauna_ci_prereq_probe -c 'ALTER SCHEMA sauna_unexpected_extensions RENAME TO extensions' > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 1 ]]
psql_cmd postgres postgres -c 'CREATE ROLE sauna_ci_unexpected_owner NOLOGIN' > /dev/null
psql_cmd postgres sauna_ci_prereq_probe -c 'ALTER SCHEMA extensions OWNER TO sauna_ci_unexpected_owner' > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 0 ]]
# Changing ownership rewrites owner ACL entries, so restore explicit USAGE
# before asserting each independent privilege canary's clean baseline.
psql_cmd postgres sauna_ci_prereq_probe -c 'ALTER SCHEMA extensions OWNER TO postgres; GRANT USAGE ON SCHEMA extensions TO sauna_admin,sauna_app; REVOKE CREATE ON SCHEMA extensions FROM sauna_admin,sauna_app;' > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 1 ]]
psql_cmd postgres sauna_ci_prereq_probe -c 'GRANT CREATE ON SCHEMA extensions TO sauna_app' > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 0 ]]
psql_cmd postgres sauna_ci_prereq_probe -c 'REVOKE CREATE ON SCHEMA extensions FROM sauna_app' > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 1 ]]
psql_cmd postgres postgres -c 'GRANT pg_read_server_files TO sauna_app' > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 0 ]]
psql_cmd postgres postgres -c 'REVOKE pg_read_server_files FROM sauna_app' > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 1 ]]
psql_cmd postgres postgres -c 'GRANT pg_execute_server_program TO sauna_admin' > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 0 ]]
psql_cmd postgres postgres -c 'REVOKE pg_execute_server_program FROM sauna_admin' > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 1 ]]
psql_cmd postgres sauna_ci_prereq_probe -c "DROP EXTENSION btree_gist; GRANT CREATE ON SCHEMA extensions TO sauna_ci_unexpected_owner; GRANT CREATE ON DATABASE sauna_ci_prereq_probe TO sauna_ci_unexpected_owner; SET ROLE sauna_ci_unexpected_owner; CREATE EXTENSION btree_gist WITH SCHEMA extensions VERSION '1.8'; RESET ROLE; REVOKE CREATE ON SCHEMA extensions FROM sauna_ci_unexpected_owner; REVOKE CREATE ON DATABASE sauna_ci_prereq_probe FROM sauna_ci_unexpected_owner;" > /dev/null
[[ $(psql_cmd sauna_admin sauna_ci_prereq_probe --command="$verify_sql") == 0 ]]
printf 'PostgreSQL prerequisite missing/version/namespace/owner/privilege canaries passed\n'
# The socket is explicit in the driver URL; no PGHOST/service/password settings
# can redirect Atlas toward the developer's active database.
target="postgres://sauna_admin@/sauna_atlas_replay?host=$socket&sslmode=disable&search_path=public"
dev="postgres://sauna_admin@/sauna_ci_dev?host=$socket&sslmode=disable&search_path=public"
atlas="$run_dir/atlas"
[[ $(psql_cmd sauna_admin sauna_atlas_replay -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'") == 0 ]]
"$atlas" migrate validate --dir "file://$run_dir/db/migrations" > "$run_dir/validate.log" 2>&1
"$atlas" migrate apply --url "$target" --dir "file://$run_dir/db/migrations" > "$run_dir/apply.log" 2>&1
journal_before=$(psql_cmd sauna_admin sauna_atlas_replay -c 'SELECT row_to_json(r)::text FROM public.atlas_schema_revisions r ORDER BY version')
[[ -n $journal_before ]]
"$atlas" migrate apply --url "$target" --dir "file://$run_dir/db/migrations" > "$run_dir/reapply.log" 2>&1
journal_after=$(psql_cmd sauna_admin sauna_atlas_replay -c 'SELECT row_to_json(r)::text FROM public.atlas_schema_revisions r ORDER BY version')
[[ $journal_before == "$journal_after" ]]
check_diff() {
    "$atlas" schema diff --from "$target" --to "file://$run_dir/db/schema.sql" --dev-url "$dev" --exclude atlas_schema_revisions --format '{{ sql . }}' > "$run_dir/diff.sql" 2> "$run_dir/diff.log"
    [[ ! -s "$run_dir/diff.sql" ]]
}
check_diff
[[ $(psql_cmd sauna_admin sauna_atlas_replay --command="$verify_sql") == 1 ]]
[[ $(psql_cmd sauna_admin sauna_ci_dev --command="$verify_sql") == 1 ]]
psql_cmd sauna_admin sauna_atlas_replay -c 'ALTER TABLE public.facilities ADD COLUMN sauna_ci_drift_probe integer' > /dev/null
# Check the actual diff result and retained column separately: a command failure
# or a verifier that silently repairs the database must not pass this canary.
"$atlas" schema diff --from "$target" --to "file://$run_dir/db/schema.sql" --dev-url "$dev" --exclude atlas_schema_revisions --format '{{ sql . }}' > "$run_dir/drift.sql" 2> "$run_dir/drift.log"
[[ -s "$run_dir/drift.sql" ]]
grep -q sauna_ci_drift_probe "$run_dir/drift.sql"
[[ $(psql_cmd sauna_admin sauna_atlas_replay -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='facilities' AND column_name='sauna_ci_drift_probe'") == 1 ]]
psql_cmd sauna_admin sauna_atlas_replay -c 'ALTER TABLE public.facilities DROP COLUMN sauna_ci_drift_probe' > /dev/null
check_diff
# Column parity alone would not prove that Atlas CE still inspects exclusion
# constraints after an upgrade. Detect its removal without silently repairing it.
exclusion_definition=$(psql_cmd sauna_admin sauna_atlas_replay -c "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='public.inventory_claims'::regclass AND conname='inventory_claim_no_overlap' AND contype='x'")
[[ -n $exclusion_definition ]]
psql_cmd sauna_admin sauna_atlas_replay -c 'ALTER TABLE public.inventory_claims DROP CONSTRAINT inventory_claim_no_overlap' > /dev/null
"$atlas" schema diff --from "$target" --to "file://$run_dir/db/schema.sql" --dev-url "$dev" --exclude atlas_schema_revisions --format '{{ sql . }}' > "$run_dir/exclusion-drift.sql" 2> "$run_dir/exclusion-drift.log"
[[ -s "$run_dir/exclusion-drift.sql" ]]
grep -q inventory_claim_no_overlap "$run_dir/exclusion-drift.sql"
[[ $(psql_cmd sauna_admin sauna_atlas_replay -c "SELECT count(*) FROM pg_constraint WHERE conrelid='public.inventory_claims'::regclass AND conname='inventory_claim_no_overlap'") == 0 ]]
psql_cmd sauna_admin sauna_atlas_replay -c "ALTER TABLE public.inventory_claims ADD CONSTRAINT inventory_claim_no_overlap $exclusion_definition" > /dev/null
check_diff
psql_cmd sauna_admin sauna_atlas_replay <<'SQL' > /dev/null
REVOKE CREATE ON SCHEMA public FROM PUBLIC, sauna_app;
GRANT USAGE ON SCHEMA public TO sauna_app;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO sauna_app;
REVOKE ALL ON public.atlas_schema_revisions FROM sauna_app;
REVOKE ALL ON public.workspace_employment_revocation_audit FROM PUBLIC, sauna_app;
REVOKE ALL (claim_token, facility_id, user_id, revoked_at) ON public.workspace_employment_revocation_audit FROM PUBLIC, sauna_app;
GRANT INSERT (claim_token, facility_id, user_id) ON public.workspace_employment_revocation_audit TO sauna_app;
SQL
count=0
for file in "$run_dir"/db/tests/*.sql; do
    [[ -f $file && ! -L $file ]]
    psql_cmd sauna_app sauna_atlas_replay --file="$file" > "$run_dir/app-test.log" 2>&1
    count=$((count + 1))
done
[[ $count -gt 0 ]]
# Rolled-back fixture tests cannot leave synthetic business rows behind.
[[ $(psql_cmd sauna_admin sauna_atlas_replay -c 'SELECT (SELECT count(*) FROM public.facilities)+(SELECT count(*) FROM public.users)') == 0 ]]
# Run the actual retention SQL against three synthetic events after checking ownership refusal.
retention_file="$run_dir/audit-retention-apply.sql"
expect_retention_refusal() {
    if psql_cmd "$1" "$2" --file="$retention_file" > "$run_dir/retention-refusal.log" 2>&1; then
        return 1
    fi
    grep -Fq 'Refusing unowned audit sandbox database' "$run_dir/retention-refusal.log"
}
expect_retention_refusal sauna_admin sauna_audit_sandbox
psql_cmd sauna_admin sauna_audit_sandbox --command="COMMENT ON DATABASE sauna_audit_sandbox IS 'an-unexpected-marker'" > /dev/null
expect_retention_refusal sauna_admin sauna_audit_sandbox
psql_cmd sauna_admin sauna_atlas_replay --command="COMMENT ON DATABASE sauna_atlas_replay IS 'sauna-local-atlas-v1'" > /dev/null
expect_retention_refusal sauna_admin sauna_atlas_replay
psql_cmd sauna_admin sauna_audit_sandbox --file="$run_dir/audit-retention-marker.sql" > /dev/null
expect_retention_refusal sauna_admin sauna_atlas_replay
expect_retention_refusal sauna_app sauna_audit_sandbox
psql_cmd postgres postgres --command="ALTER DATABASE sauna_audit_sandbox OWNER TO postgres" > /dev/null
expect_retention_refusal sauna_admin sauna_audit_sandbox
psql_cmd postgres postgres --command="ALTER DATABASE sauna_audit_sandbox OWNER TO sauna_admin" > /dev/null
audit_target="postgres://sauna_admin@/sauna_audit_sandbox?host=$socket&sslmode=disable&search_path=public"
"$atlas" migrate apply --url "$audit_target" --dir "file://$run_dir/db/migrations" > "$run_dir/audit-apply.log" 2>&1
psql_cmd sauna_admin sauna_audit_sandbox <<'SQL' > /dev/null
INSERT INTO public.workspace_employment_revocation_audit (claim_token, facility_id, user_id, revoked_at)
SELECT ('46000000-0000-0000-0000-00000000000' || id)::uuid,
       facility,
       '46000000-0000-0000-0000-000000000005',
       statement_timestamp() - make_interval(days => age)
FROM (VALUES (1, 60, '46000000-0000-0000-0000-000000000004'::uuid),
             (2, 40, '46000000-0000-0000-0000-000000000006'::uuid),
             (3, 5,  '46000000-0000-0000-0000-000000000004'::uuid)) seed(id, age, facility);

CREATE SCHEMA audit_review;
REVOKE ALL ON SCHEMA audit_review FROM PUBLIC;
-- A caller-set value cannot define the facility boundary. The barrier keeps
-- caller predicates from receiving values outside the chosen facility.
CREATE VIEW audit_review.employment_revocations WITH (security_barrier = true) AS
SELECT claim_token, facility_id, user_id, revoked_at
FROM public.workspace_employment_revocation_audit
WHERE facility_id = '46000000-0000-0000-0000-000000000004'::uuid;
GRANT USAGE ON SCHEMA audit_review TO sauna_audit_reviewer;
GRANT SELECT ON audit_review.employment_revocations TO sauna_audit_reviewer;
SQL
audit_review() {
    psql_cmd sauna_audit_reviewer sauna_audit_sandbox "$@"
}
[[ $(audit_review -c "SELECT session_user=current_user AND current_user='sauna_audit_reviewer'") == t ]]
[[ $(audit_review -c "SELECT string_agg(right(claim_token::text, 1), ',' ORDER BY revoked_at) FROM audit_review.employment_revocations") == '1,3' ]]
[[ $(audit_review -c "SELECT count(*) FROM audit_review.employment_revocations WHERE facility_id='46000000-0000-0000-0000-000000000006'") == 0 ]]
[[ $(audit_review -c "SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
    FROM information_schema.columns WHERE table_schema='audit_review' AND table_name='employment_revocations'") == 'claim_token,facility_id,user_id,revoked_at' ]]
expect_audit_review_denial() {
    if audit_review --set=VERBOSITY=verbose --command="$1" > "$run_dir/audit-review-denial.log" 2>&1; then
        return 1
    fi
    grep -Fq 'ERROR:  42501:' "$run_dir/audit-review-denial.log"
}
expect_audit_review_denial 'SELECT * FROM public.workspace_employment_revocation_audit'
expect_audit_review_denial 'INSERT INTO audit_review.employment_revocations DEFAULT VALUES'
expect_audit_review_denial 'UPDATE audit_review.employment_revocations SET revoked_at=statement_timestamp()'
expect_audit_review_denial 'DELETE FROM audit_review.employment_revocations'
expect_audit_review_denial 'DELETE FROM public.workspace_employment_revocation_audit'
expect_audit_review_denial 'SET ROLE sauna_admin'
expect_audit_review_denial 'SET ROLE sauna_app'
if psql_cmd sauna_audit_reviewer sauna_atlas_replay -c 'SELECT current_user' > "$run_dir/audit-review-connection.log" 2>&1; then
    exit 1
fi
grep -Fq 'pg_hba.conf rejects connection' "$run_dir/audit-review-connection.log"
printf 'Facility audit reviewer canaries passed: scoped SELECT and denied base table, writes, role changes, and replay connection\n'
retention_count() {
    psql_cmd sauna_admin sauna_audit_sandbox --quiet --file="$1"
}
audit_remaining() {
    psql_cmd sauna_admin sauna_audit_sandbox --command="SELECT string_agg(right(claim_token::text, 1), ',' ORDER BY revoked_at) FROM public.workspace_employment_revocation_audit"
}
[[ $(retention_count "$run_dir/audit-retention-preview.sql") == 1 && $(audit_remaining) == '1,2,3' ]]
# Hold the oldest row in another transaction until the first batch completes.
# The readiness marker must follow a successful row lock so this cannot pass
# because the retention batch ran before its competing transaction.
coproc AUDIT_LOCK {
    psql_cmd sauna_admin sauna_audit_sandbox --quiet > "$run_dir/audit-lock.log" 2>&1
}
audit_lock_pid=$AUDIT_LOCK_PID
audit_lock_input=${AUDIT_LOCK[1]}
cat >&"$audit_lock_input" <<'SQL'
BEGIN;
SET LOCAL statement_timeout = '5s';
SET LOCAL idle_in_transaction_session_timeout = '20s';
SELECT claim_token FROM public.workspace_employment_revocation_audit
ORDER BY revoked_at, claim_token LIMIT 1 FOR UPDATE \gset
\echo audit-lock-acquired
SQL
audit_lock_deadline=$((SECONDS + 5))
until grep -Fxq audit-lock-acquired "$run_dir/audit-lock.log"; do
    [[ $SECONDS -lt $audit_lock_deadline ]] && kill -0 "$audit_lock_pid" 2>/dev/null || exit 1
    sleep 0.05
done
[[ $(retention_count "$retention_file") == 1 && $(audit_remaining) == '1,3' ]]
printf 'ROLLBACK;\n\\q\n' >&"$audit_lock_input"
wait "$audit_lock_pid"
[[ $(retention_count "$retention_file") == 1 && $(audit_remaining) == 3 ]]
[[ $(retention_count "$retention_file") == 0 && $(audit_remaining) == 3 ]]
[[ $(psql_cmd sauna_admin sauna_atlas_replay --command="$verify_sql") == 1 ]]
[[ $(psql_cmd sauna_admin sauna_ci_dev --command="$verify_sql") == 1 ]]
printf 'PostgreSQL 18 peer replay passed: fresh apply, unchanged reapply journal, schema parity, retained drift detection, %s restricted-role SQL suites, guarded audit retention with a locked row\n' "$count"
