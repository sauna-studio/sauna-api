#!/usr/bin/env python3
"""Run Swift tests against a fresh local PostgreSQL VM, preserving existing DBs."""
import argparse
import json
import os
from pathlib import Path
import platform
import signal
import socket
import stat
import subprocess
import tempfile
import time
import uuid

import migration_ci
import postgresql_prerequisites as prerequisites
from pglast import parse_sql, enums

ROOT = Path(__file__).resolve().parents[1]
PORT = 55433
LABEL = 'studio.sauna.integration-db'

BOOTSTRAP = r'''set -eu
umask 077
run_dir=$(mktemp -d /tmp/sauna-integration.XXXXXXXX)
cp /input/schema.sql "$run_dir/schema.sql"
cp /input/start.sh "$run_dir/start.sh"
cp /input/prerequisites-bootstrap.sql "$run_dir/prerequisites-bootstrap.sql"
cp /input/prerequisites-verify.sql "$run_dir/prerequisites-verify.sql"
cp /approved/app-password "$run_dir/app-password"
chmod 600 "$run_dir/app-password"
chown -R postgres:postgres "$run_dir"
exec gosu postgres env -i PATH=/usr/lib/postgresql/18/bin:/usr/local/bin:/usr/bin:/bin HOME="$run_dir" LANG=C.UTF-8 /bin/bash "$run_dir/start.sh" "$run_dir"
'''

START = r'''set -euo pipefail
umask 077
run_dir=$1
cluster="$run_dir/cluster"
socket="$run_dir/socket"
mkdir -m 700 "$socket"
initdb --pgdata="$cluster" --auth-local=peer --auth-host=reject > "$run_dir/init.log" 2>&1
printf 'sauna_ci postgres sauna_admin\n' > "$cluster/pg_ident.conf"
printf 'local all postgres peer\nlocal all sauna_admin peer map=sauna_ci\nhost sauna_atlas_replay sauna_app 0.0.0.0/0 scram-sha-256\nhost all all 0.0.0.0/0 reject\nhost all all ::0/0 reject\n' > "$cluster/pg_hba.conf"
pg_ctl --pgdata="$cluster" --log="$run_dir/server.log" --options="-c listen_addresses='0.0.0.0' -c unix_socket_directories='$socket' -c unix_socket_permissions=0700 -c password_encryption=scram-sha-256 -c log_statement=none -c log_min_error_statement=panic -c log_error_verbosity=terse" --wait start > /dev/null
trap 'pg_ctl --pgdata="$cluster" --mode=immediate --wait stop > /dev/null 2>&1 || true' EXIT
psql --no-password --no-psqlrc --host="$socket" --username=postgres --dbname=postgres --set=ON_ERROR_STOP=1 <<'SQL' > "$run_dir/setup.log" 2>&1
CREATE ROLE sauna_admin LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE sauna_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE DATABASE sauna_atlas_replay OWNER sauna_admin;
SQL
# Only fixed reviewed prerequisite SQL is staged; no data-defined superuser program.
bootstrap_sql=$(cat "$run_dir/prerequisites-bootstrap.sql")
verify_sql=$(cat "$run_dir/prerequisites-verify.sql")
psql --no-password --no-psqlrc --host="$socket" --username=postgres --dbname=sauna_atlas_replay --set=ON_ERROR_STOP=1 --command="SET statement_timeout='10s';
$bootstrap_sql" > "$run_dir/prerequisites.log" 2>&1
[[ $(psql --no-password --no-psqlrc --host="$socket" --username=sauna_admin --dbname=sauna_atlas_replay --set=ON_ERROR_STOP=1 --tuples-only --no-align --command="$verify_sql") == 1 ]]
psql --no-password --no-psqlrc --host="$socket" --username=postgres --dbname=postgres --set=ON_ERROR_STOP=1 --set=secret_file="$run_dir/app-password" <<'SQL' >> "$run_dir/setup.log" 2>&1
SELECT set_config('sauna.integration_password_file', :'secret_file', false);
DO $body$
DECLARE value text := rtrim(pg_read_file(current_setting('sauna.integration_password_file')), E'\n');
BEGIN
 IF value !~ '^[A-Za-z0-9_-]{48}$' THEN RAISE EXCEPTION 'Invalid approved password file'; END IF;
 EXECUTE format('ALTER ROLE sauna_app PASSWORD %L', value);
END;
$body$;
SQL
rm "$run_dir/app-password"
# Do not allow psql's single-backslash-command mode for candidate input.
schema_sql=$(cat "$run_dir/schema.sql")
psql --no-password --no-psqlrc --host="$socket" --username=sauna_admin --dbname=sauna_atlas_replay --set=ON_ERROR_STOP=1 --command="SET statement_timeout='10s';
$schema_sql" > "$run_dir/schema.log" 2>&1
psql --no-password --no-psqlrc --host="$socket" --username=sauna_admin --dbname=sauna_atlas_replay --set=ON_ERROR_STOP=1 <<'SQL' > "$run_dir/grants.log" 2>&1
REVOKE CREATE ON SCHEMA public FROM PUBLIC, sauna_app;
GRANT USAGE ON SCHEMA public TO sauna_app;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO sauna_app;
SQL
[[ $(psql --no-password --no-psqlrc --host="$socket" --username=sauna_admin --dbname=sauna_atlas_replay --set=ON_ERROR_STOP=1 --tuples-only --no-align --command="$verify_sql") == 1 ]]
touch /tmp/sauna-integration-ready
while sleep 30; do :; done
'''


def command(args, timeout=30):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Integration DB command failed; raw diagnostics suppressed')
    return result.stdout


def approved_password():
    common = Path(command(['git', 'rev-parse', '--git-common-dir']).strip())
    if not common.is_absolute():
        common = ROOT / common
    base = common.resolve().parent / '.local'
    for directory in [base, base / 'secrets']:
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise RuntimeError('Approved private credential directory is required')
    path = base / 'secrets/postgres-app-password'
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size not in (48, 49):
        raise RuntimeError('Approved owner-only local app password file is required')
    return path


def stage_password(source, destination):
    # Apple file sharing accepts directories. Never mount the parent secrets
    # directory: it also contains an administrator credential.
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as reader:
        info = os.fstat(reader.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size not in (48, 49):
            raise RuntimeError('Credential file changed before staging')
        out = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(out, 'wb') as writer:
            writer.write(reader.read(64))


def ensure_port_free():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        try:
            probe.bind(('127.0.0.1', PORT))
        except OSError:
            raise RuntimeError('Dedicated integration port 55433 is occupied; no listener was stopped') from None


def validate_schema(content):
    try:
        statements = parse_sql(content.decode('utf-8'))
    except Exception:
        raise RuntimeError('Candidate schema must contain PostgreSQL DDL only') from None
    if not statements:
        raise RuntimeError('Candidate schema cannot be empty')
    for statement in statements:
        node = statement.stmt
        kind = type(node).__name__
        if kind == 'AlterTableStmt':
            if not all(cmd.subtype == enums.AlterTableType.AT_AddConstraint for cmd in node.cmds):
                raise RuntimeError('Schema alteration requires a reviewed policy extension')
        elif kind not in {'CreateStmt', 'IndexStmt'}:
            raise RuntimeError('Schema statement requires a reviewed policy extension')


def cleanup(name, owner):
    names = command(['container', 'list', '--all', '--quiet']).splitlines()
    if name not in names:
        return
    items = json.loads(command(['container', 'inspect', name]))
    if len(items) != 1 or items[0]['configuration']['id'] != name or items[0]['configuration'].get('labels', {}).get(LABEL) != owner:
        raise RuntimeError('Refusing to remove a foreign integration container')
    command(['container', 'delete', '--force', name])


def run_tests(scratch=None, test_filter=None):
    if platform.system() != 'Darwin':
        raise RuntimeError('Local integration tests require Apple container on macOS')
    ensure_port_free()
    snapshot = migration_ci.validated_inputs()
    validate_schema(snapshot['db/schema.sql'])
    prerequisites.validate_manifest(snapshot.get('db/postgresql-prerequisites.json'))
    password = approved_password()
    owner = str(uuid.uuid4())
    name = 'sauna-integration-db-' + owner
    with tempfile.TemporaryDirectory(prefix='sauna-integration-db-') as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        public = directory / 'public'
        private = directory / 'credential'
        public.mkdir(mode=0o700)
        private.mkdir(mode=0o700)
        (public / 'schema.sql').write_bytes(snapshot['db/schema.sql'])
        (public / 'start.sh').write_text(START)
        (public / 'prerequisites-bootstrap.sql').write_text(prerequisites.BOOTSTRAP_SQL)
        (public / 'prerequisites-verify.sql').write_text(prerequisites.VERIFY_SQL)
        stage_password(password, private / 'app-password')
        try:
            command(['container', 'run', '--detach', '--rm', '--name', name,
                     '--label', LABEL + '=' + owner, '--read-only', '--tmpfs', '/tmp',
                     '--cpus', '2', '--memory', '768M', '--no-dns',
                     '--publish', f'127.0.0.1:{PORT}:5432', '--entrypoint', '/bin/sh',
                     '--mount', f'type=bind,source={public},target=/input,readonly',
                     '--mount', f'type=bind,source={private},target=/approved,readonly',
                     migration_ci.IMAGE, '-c', BOOTSTRAP], timeout=60)
            deadline = time.monotonic() + 40
            while True:
                ready = subprocess.run(['container', 'exec', '--user', 'postgres', name,
                                        '/usr/bin/test', '-f', '/tmp/sauna-integration-ready'],
                                       capture_output=True, timeout=10)
                if ready.returncode == 0:
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError('Fresh integration database did not become ready; logs remain private')
                time.sleep(0.5)
            (private / 'app-password').unlink()
            env = os.environ.copy()
            env.update(PGHOST='127.0.0.1', PGPORT=str(PORT), PGUSER='sauna_app',
                       PGDATABASE='sauna_atlas_replay', PGPASSWORD_FILE=str(password))
            args = ['xcrun', 'swift', 'test', '--force-resolved-versions']
            if scratch:
                args += ['--scratch-path', scratch]
            if test_filter:
                args += ['--filter', test_filter]
            print('Swift tests use a new owned PostgreSQL VM on loopback:55433; existing DBs are unchanged', flush=True)
            return subprocess.run(args, cwd=ROOT, env=env, timeout=1200).returncode
        finally:
            cleanup(name, owner)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scratch-path')
    parser.add_argument('--filter')
    args = parser.parse_args()
    def terminate(_signal, _frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, terminate)
    return run_tests(args.scratch_path, args.filter)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt):
        raise SystemExit('Local integration test failed; credential-bearing diagnostics suppressed') from None
