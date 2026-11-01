#!/usr/bin/env python3
"""Atlas Community workflow for owned local PostgreSQL only; never logs credentials."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

import local_postgres as db
from pglast import parse_sql, enums

ROOT = Path(__file__).resolve().parents[1]
ATLAS = ROOT.parent / '.tools/atlas/atlas'
MIGRATIONS = ROOT / 'db/migrations'
MARKER = 'sauna-local-atlas-v1'
SCRATCH = {'sauna_atlas_dev', 'sauna_atlas_replay'}
TABLES = ('facilities', 'users', 'facility_memberships', 'products', 'reservations', 'reservation_items', 'webauthn_challenges', 'passkey_accounts', 'passkey_registration_intents', 'passkey_credentials', 'auth_sessions', 'passkey_management_intents', 'product_offerings')


def guard(base='HEAD', directory=MIGRATIONS):
    """Fail closed on non-additive DDL and on changes to migration SQL in trusted Git base."""
    listed = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', base, '--', 'db/migrations'], cwd=ROOT, text=True)
    old = {}
    for name in listed.splitlines():
        if name.endswith('.sql'):
            old[Path(name).name] = subprocess.check_output(['git', 'show', f'{base}:{name}'], cwd=ROOT)
    if directory.is_symlink():
        raise RuntimeError('Refusing symlinked migration directory')
    current = {}
    for path in sorted(directory.glob('*.sql')):
        if path.is_symlink() or not re.fullmatch(r'\d{14}_[a-z0-9_]+\.sql', path.name):
            raise RuntimeError('Invalid migration name or symlink')
        current[path.name] = path.read_bytes()
        try:
            statements = parse_sql(current[path.name].decode())
        except Exception:
            raise RuntimeError('Migration SQL could not be parsed') from None
        if not statements:
            raise RuntimeError('Empty migration is not allowed')
        for statement in statements:
            node = statement.stmt
            kind = type(node).__name__
            allowed = kind in {'CreateStmt', 'IndexStmt'}
            if kind == 'AlterTableStmt':
                allowed = all(command.subtype == enums.AlterTableType.AT_AddConstraint for command in node.cmds)
            if not allowed:
                raise RuntimeError('Migration requires a separately reviewed policy extension: ' + kind)
    if not current:
        raise RuntimeError('No migration SQL found')
    for name, content in old.items():
        if current.get(name) != content:
            raise RuntimeError('Previously committed migration was modified or removed')
    if old and any(name <= max(old) for name in current.keys() - old.keys()):
        raise RuntimeError('New migrations must follow the trusted base versions')
    return len(current)


def prepare():
    db.owned()
    for name in sorted(SCRATCH):
        state = db.query(f"SELECT pg_get_userbyid(datdba)||'|'||coalesce(shobj_description(oid,'pg_database'),'') FROM pg_database WHERE datname='{name}';").strip()
        if not state:
            db.query(f'CREATE DATABASE {name} OWNER sauna_admin;')
            db.query(f"COMMENT ON DATABASE {name} IS '{MARKER}';")
        elif state != 'sauna_admin|' + MARKER:
            raise RuntimeError('Refusing unowned scratch database')


def reset_replay():
    # Destruction is restricted to the labelled, tool-owned disposable replay DB.
    prepare()
    db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;', database='sauna_atlas_replay')


@contextmanager
def configuration(target='sauna_local'):
    if target not in {'sauna_local', 'sauna_atlas_replay'}:
        raise RuntimeError('Unexpected Atlas target')
    prepare()
    db.verify_directory()
    password = db.verify_file(db.DIRECTORY / db.FILES['admin'])
    def url(database):
        return f'postgres://sauna_admin:{password}@127.0.0.1:55432/{database}?sslmode=disable&search_path=public'
    # Private ephemeral config keeps URL/password out of process argv and environment.
    with tempfile.TemporaryDirectory(prefix='sauna-atlas-') as temporary:
        config = Path(temporary) / 'atlas.hcl'
        fd = os.open(config, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        values = {'url': url(target), 'dev': url('sauna_atlas_dev'), 'src': (ROOT / 'db/schema.sql').as_uri()}
        with os.fdopen(fd, 'w') as stream:
            stream.write('env "local" {\n')
            for key, value in values.items():
                stream.write(f'  {key} = {json.dumps(value)}\n')
            stream.write('  migration {\n    dir = '+json.dumps(MIGRATIONS.as_uri())+'\n  }\n}\n')
        yield config


def atlas(args, config):
    if not ATLAS.is_file():
        raise RuntimeError('Workspace-local Atlas Community installation is required')
    # Fixed executable version and digest, not a binary replaced elsewhere on PATH.
    if hashlib.sha256(ATLAS.read_bytes()).hexdigest() != '4e5ffdc10b2b4fd3a06074aba72848150907d5316cacad7b19bae6c6ae3db991':
        raise RuntimeError('Atlas Community executable checksum mismatch')
    result = subprocess.run([str(ATLAS), *args, '--config', config.as_uri(), '--env', 'local'], cwd=ROOT, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError('Atlas command failed; credential-bearing diagnostics suppressed')
    return result.stdout


def grant_app(database='sauna_local'):
    db.configure_role()
    names = ', '.join('public.' + name for name in TABLES)
    db.query(f'REVOKE CREATE ON SCHEMA public FROM PUBLIC, sauna_app; GRANT USAGE ON SCHEMA public TO sauna_app; GRANT SELECT, INSERT, UPDATE, DELETE ON {names} TO sauna_app;', database=database)


def check_drift(config):
    sql = atlas(['schema', 'diff', '--from', 'env://url', '--to', 'env://src', '--exclude', 'atlas_schema_revisions', '--format', '{{ sql . }}'], config)
    if sql.strip():
        raise RuntimeError('Schema drift detected; no automatic repair was applied')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['generate', 'guard', 'apply', 'verify', 'test'])
    parser.add_argument('--name', default='initial_schema')
    parser.add_argument('--base', default='HEAD', help='Trusted Git base for migration immutability (CI: PR base SHA)')
    args = parser.parse_args()
    if args.action == 'guard':
        count = guard(args.base)
        print(f'Migration policy/immutability verified: {count} files')
        return
    if args.action == 'generate':
        if not re.fullmatch(r'[a-z][a-z0-9_]{0,60}', args.name):
            raise RuntimeError('Invalid migration name')
        MIGRATIONS.mkdir(exist_ok=True, parents=True)
        with configuration() as config:
            atlas(['migrate', 'diff', args.name], config)
        guard(args.base)
        print('Atlas migration generated; review schema and SQL before apply')
        return
    guard(args.base)
    if args.action == 'test':
        # Test data never touches the persistent application database.
        reset_replay()
        with configuration('sauna_atlas_replay') as config:
            atlas(['migrate', 'apply'], config)
            atlas(['migrate', 'apply'], config)
            check_drift(config)
            # A real committed drift in the disposable replay DB must be detected,
            # left intact by verification, and repaired only by this explicit test.
            db.query('ALTER TABLE public.facilities ADD COLUMN sauna_drift_probe integer;', database='sauna_atlas_replay')
            try:
                try:
                    check_drift(config)
                except RuntimeError as error:
                    if str(error) != 'Schema drift detected; no automatic repair was applied':
                        raise
                else:
                    raise RuntimeError('Drift canary was not detected')
                retained = db.query("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='facilities' AND column_name='sauna_drift_probe';", database='sauna_atlas_replay')
                if retained.strip() != '1':
                    raise RuntimeError('Drift verification unexpectedly changed the database')
            finally:
                db.query('ALTER TABLE public.facilities DROP COLUMN sauna_drift_probe;', database='sauna_atlas_replay')
            check_drift(config)
        grant_app('sauna_atlas_replay')
        tests = sorted((ROOT / 'db/tests').glob('*.sql'))
        if not tests:
            raise RuntimeError('No SQL tests found')
        for path in tests:
            if path.is_symlink():
                raise RuntimeError('Refusing symlinked SQL test')
            db.query(path.read_text(), database='sauna_atlas_replay', role='app')
        print('Fresh replay, repeated apply, schema parity, real drift rejection and app-role SQL tests passed')
    else:
        with configuration() as config:
            atlas(['migrate', 'validate'], config)
            if args.action == 'apply':
                atlas(['migrate', 'apply'], config)
                grant_app()
            check_drift(config)
        print('Local migration integrity and schema parity verified')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit('Local migration action failed. Credentials and raw diagnostics are suppressed.') from None
