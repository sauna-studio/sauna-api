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
# Peer retains kernel identity checks. The two exact mappings exercise SQL role
# separation; they do not pretend that one OS user becomes two isolated users.
printf 'sauna_ci postgres sauna_admin\nsauna_ci postgres sauna_app\n' > "$cluster/pg_ident.conf"
printf 'local all all peer map=sauna_ci\nhost all all 0.0.0.0/0 reject\nhost all all ::0/0 reject\n' > "$cluster/pg_hba.conf"
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
CREATE DATABASE sauna_ci_replay OWNER sauna_admin;
CREATE DATABASE sauna_ci_dev OWNER sauna_admin;
SQL
[[ $(psql_cmd postgres postgres -c 'SHOW listen_addresses') == '' ]]
[[ $(psql_cmd sauna_app sauna_ci_replay -c "SELECT session_user=current_user AND session_user='sauna_app'") == t ]]
# The socket is explicit in the driver URL; no PGHOST/service/password settings
# can redirect Atlas toward the developer's active database.
target="postgres://sauna_admin@/sauna_ci_replay?host=$socket&sslmode=disable&search_path=public"
dev="postgres://sauna_admin@/sauna_ci_dev?host=$socket&sslmode=disable&search_path=public"
atlas="$run_dir/atlas"
[[ $(psql_cmd sauna_admin sauna_ci_replay -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'") == 0 ]]
"$atlas" migrate validate --dir "file://$run_dir/db/migrations" > "$run_dir/validate.log" 2>&1
"$atlas" migrate apply --url "$target" --dir "file://$run_dir/db/migrations" > "$run_dir/apply.log" 2>&1
journal_before=$(psql_cmd sauna_admin sauna_ci_replay -c 'SELECT row_to_json(r)::text FROM public.atlas_schema_revisions r ORDER BY version')
[[ -n $journal_before ]]
"$atlas" migrate apply --url "$target" --dir "file://$run_dir/db/migrations" > "$run_dir/reapply.log" 2>&1
journal_after=$(psql_cmd sauna_admin sauna_ci_replay -c 'SELECT row_to_json(r)::text FROM public.atlas_schema_revisions r ORDER BY version')
[[ $journal_before == "$journal_after" ]]
check_diff() {
    "$atlas" schema diff --from "$target" --to "file://$run_dir/db/schema.sql" --dev-url "$dev" --exclude atlas_schema_revisions --format '{{ sql . }}' > "$run_dir/diff.sql" 2> "$run_dir/diff.log"
    [[ ! -s "$run_dir/diff.sql" ]]
}
check_diff
psql_cmd sauna_admin sauna_ci_replay -c 'ALTER TABLE public.facilities ADD COLUMN sauna_ci_drift_probe integer' > /dev/null
# Check the actual diff result and retained column separately: a command failure
# or a verifier that silently repairs the database must not pass this canary.
"$atlas" schema diff --from "$target" --to "file://$run_dir/db/schema.sql" --dev-url "$dev" --exclude atlas_schema_revisions --format '{{ sql . }}' > "$run_dir/drift.sql" 2> "$run_dir/drift.log"
[[ -s "$run_dir/drift.sql" ]]
grep -q sauna_ci_drift_probe "$run_dir/drift.sql"
[[ $(psql_cmd sauna_admin sauna_ci_replay -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='facilities' AND column_name='sauna_ci_drift_probe'") == 1 ]]
psql_cmd sauna_admin sauna_ci_replay -c 'ALTER TABLE public.facilities DROP COLUMN sauna_ci_drift_probe' > /dev/null
check_diff
psql_cmd sauna_admin sauna_ci_replay <<'SQL' > /dev/null
REVOKE CREATE ON SCHEMA public FROM PUBLIC, sauna_app;
GRANT USAGE ON SCHEMA public TO sauna_app;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO sauna_app;
REVOKE ALL ON public.atlas_schema_revisions FROM sauna_app;
SQL
count=0
for file in "$run_dir"/db/tests/*.sql; do
    [[ -f $file && ! -L $file ]]
    psql_cmd sauna_app sauna_ci_replay --file="$file" > "$run_dir/app-test.log" 2>&1
    count=$((count + 1))
done
[[ $count -gt 0 ]]
# Rolled-back fixture tests cannot leave synthetic business rows behind.
[[ $(psql_cmd sauna_admin sauna_ci_replay -c 'SELECT (SELECT count(*) FROM public.facilities)+(SELECT count(*) FROM public.users)') == 0 ]]
printf 'PostgreSQL 18 peer replay passed: fresh apply, unchanged reapply journal, schema parity, retained drift detection, %s restricted-role SQL suites\n' "$count"
