#!/usr/bin/env python3
"""Verify migrations in a new socket-only PostgreSQL container, never a live DB."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
IMAGE = 'docker.io/library/postgres:18@sha256:979bccfde35445db618c65107d27d08c6c21339d8dc3ad4c830c6633947be0e4'
LABEL = 'studio.sauna.migration-ci'
ATLAS_VERSION = '1.3.0'
ATLAS_HASHES = {
    'darwin-arm64': '4e5ffdc10b2b4fd3a06074aba72848150907d5316cacad7b19bae6c6ae3db991',
    'linux-arm64': '082188c57a53439596a3ee52173b12e785aa83ec718505674e2052db0fec0c4c',
    'linux-amd64': '10d7913e3dce43ab99b8d71534a4cbadaf11a16dc293adf3b91d10e83a0ac70b',
}
# Both runtimes stage only public tracked files. Root copies those inputs into a
# fresh container-local directory before dropping to the postgres OS identity.
BOOTSTRAP = '''set -eu
umask 077
run_dir=$(mktemp -d /tmp/sauna-migration-run.XXXXXXXX)
cp -R "$1"/. "$run_dir"/
chown -R postgres:postgres "$run_dir"
exec gosu postgres env -i PATH=/usr/lib/postgresql/18/bin:/usr/local/bin:/usr/bin:/bin HOME="$run_dir" LANG=C.UTF-8 /bin/bash "$run_dir/replay.sh" "$run_dir"
'''


def command(args, *, cwd=ROOT, timeout=120, env=None):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=timeout, env=env)
    if result.returncode:
        raise RuntimeError('Migration verification command failed; raw diagnostics suppressed')
    return result.stdout


def trusted_base(value):
    if not re.fullmatch(r'[0-9a-f]{40}', value) or value == '0' * 40:
        raise RuntimeError('A full nonzero trusted base SHA is required')
    command(['git', 'cat-file', '-e', value + '^{commit}'])
    command(['git', 'merge-base', '--is-ancestor', value, 'HEAD'])
    files = command(['git', 'ls-tree', '-r', '--name-only', value, '--', 'db/migrations']).splitlines()
    if not any(name.endswith('.sql') for name in files):
        raise RuntimeError('Trusted base has no historical migration SQL')
    return value


def download_atlas(kind, directory):
    expected = ATLAS_HASHES.get(kind)
    if expected is None:
        raise RuntimeError('Unsupported Atlas platform')
    target = directory / ('atlas-' + kind)
    url = f'https://release.ariga.io/atlas/atlas-community-{kind}-v{ATLAS_VERSION}'
    with urllib.request.urlopen(url, timeout=60) as source, target.open('xb') as output:
        shutil.copyfileobj(source, output)
    if hashlib.sha256(target.read_bytes()).hexdigest() != expected:
        raise RuntimeError('Official Atlas executable checksum mismatch')
    target.chmod(0o755)
    return target


def current_kind():
    system = platform.system().lower()
    machine = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'amd64'}.get(platform.machine())
    kind = f'{system}-{machine}'
    if kind not in ATLAS_HASHES:
        raise RuntimeError('Unsupported verification host')
    return kind


def guard_with_base(base, trusted, directory):
    # The PR's edited guard cannot approve its own policy exceptions. The workflow
    # itself is branch-editable, so required checks/review still form the boundary.
    program = '''import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import local_migrations as m
m.ROOT=Path(sys.argv[2])
try:
    count=m.guard(sys.argv[3], directory=Path(sys.argv[4]))
except RuntimeError as error:
    print(str(error))
    raise SystemExit(1)
print(count)
'''
    return subprocess.run([sys.executable, '-I', '-c', program, str(trusted), str(ROOT), base, str(directory)], text=True, capture_output=True, timeout=30)


def verify_guard(base, host_atlas, temporary, snapshot):
    trusted = temporary / 'trusted'
    trusted.mkdir(mode=0o700)
    for name in ['local_migrations.py', 'local_postgres.py']:
        content = subprocess.check_output(['git', 'show', base + ':scripts/' + name], cwd=ROOT)
        (trusted / name).write_bytes(content)
    result = guard_with_base(base, trusted, snapshot / 'db/migrations')
    if result.returncode:
        raise RuntimeError('Trusted migration policy rejected candidate SQL/history')
    canary = temporary / 'history-canary'
    shutil.copytree(snapshot / 'db/migrations', canary)
    first = sorted(canary.glob('*.sql'))[0]
    first.write_bytes(first.read_bytes() + b'\n-- simulated immutable-history edit\n')
    for action in ['hash', 'validate']:
        command([str(host_atlas), 'migrate', action, '--dir', canary.as_uri()])
    result = guard_with_base(base, trusted, canary)
    if result.returncode != 1 or 'Previously committed migration was modified or removed' not in result.stdout:
        raise RuntimeError('Rehashed historical SQL canary was not rejected')
    shutil.rmtree(canary)
    shutil.copytree(snapshot / 'db/migrations', canary)
    (canary / '99991231235959_destructive_canary.sql').write_text('ALTER TABLE public.facilities DROP COLUMN name;\n')
    result = guard_with_base(base, trusted, canary)
    if result.returncode != 1 or 'Migration requires a separately reviewed policy extension' not in result.stdout:
        raise RuntimeError('Destructive SQL canary was not rejected')
    print('Trusted Git policy passed; rehashed history edits and destructive DDL are rejected')


def validated_inputs():
    selected = [ROOT / 'db/schema.sql', ROOT / 'db/migrations/atlas.sum']
    selected += sorted((ROOT / 'db/migrations').glob('*.sql'))
    selected += sorted((ROOT / 'db/tests').glob('*.sql'))
    selected += [ROOT / 'scripts/migration_replay.sh']
    if not list((ROOT / 'db/tests').glob('*.sql')):
        raise RuntimeError('SQL test suites are required')
    snapshot = {}
    for source in selected:
        relative = source.relative_to(ROOT)
        if any(part.is_symlink() for part in [source, *source.parents] if part == ROOT or ROOT in part.parents):
            raise RuntimeError('Refusing symlinked staged input')
        if not source.is_file():
            raise RuntimeError('Expected regular staged input')
        command(['git', 'ls-files', '--error-unmatch', '--', relative.as_posix()])
        # Only regular validated bytes enter the private snapshot. In particular,
        # Atlas hash must never receive an atlas.sum symlink from the candidate.
        with os.fdopen(os.open(source, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise RuntimeError('Expected regular staged input')
            snapshot[relative.as_posix()] = stream.read()
    return snapshot


def stage_inputs(directory, snapshot, atlas=None):
    for relative, content in snapshot.items():
        name = 'replay.sh' if relative == 'scripts/migration_replay.sh' else relative
        destination = directory / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
        destination.chmod(0o644)
    if atlas is not None:
        shutil.copyfile(atlas, directory / 'atlas')
        (directory / 'atlas').chmod(0o755)


def cleanup_apple(name, owner):
    names = command(['container', 'list', '--all', '--quiet'], timeout=20).splitlines()
    if name not in names:
        return
    items = json.loads(command(['container', 'inspect', name], timeout=20))
    if len(items) != 1 or items[0]['configuration']['id'] != name or items[0]['configuration'].get('labels', {}).get(LABEL) != owner:
        raise RuntimeError('Refusing to remove a foreign migration container')
    command(['container', 'delete', '--force', name], timeout=30)


def replay(runtime, inputs):
    if runtime == 'ci':
        if platform.system() != 'Linux' or os.geteuid() != 0:
            raise RuntimeError('CI replay requires the isolated PostgreSQL job container')
        print(command(['/bin/sh', '-c', BOOTSTRAP, 'migration-ci', str(inputs)], timeout=240).strip())
        return
    if platform.system() != 'Darwin':
        raise RuntimeError('Local replay requires Apple container on macOS')
    owner = str(uuid.uuid4())
    name = 'sauna-migration-ci-' + owner
    # UUID identity and label are checked before cleanup; no known developer
    # container, named volume, credential mount or published port is used.
    try:
        output = command(['container', 'run', '--rm', '--name', name, '--label', LABEL + '=' + owner,
                          '--network', 'none', '--no-dns', '--read-only', '--tmpfs', '/tmp',
                          '--cpus', '2', '--memory', '768M', '--entrypoint', '/bin/sh',
                          '--mount', f'type=bind,source={inputs},target=/input,readonly',
                          IMAGE, '-c', BOOTSTRAP, 'migration-ci', '/input'], timeout=300)
        print(output.strip())
    finally:
        cleanup_apple(name, owner)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    parser.add_argument('--runtime', choices=['apple', 'ci'], default='apple')
    args = parser.parse_args()
    snapshot = validated_inputs()
    base = trusted_base(args.base)
    host_kind = current_kind()
    with tempfile.TemporaryDirectory(prefix='sauna-migration-ci-') as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        source_snapshot = directory / 'source'
        source_snapshot.mkdir(mode=0o700)
        stage_inputs(source_snapshot, snapshot)
        host_atlas = download_atlas(host_kind, directory)
        verify_guard(base, host_atlas, directory, source_snapshot)
        container_kind = 'linux-' + host_kind.split('-')[1]
        container_atlas = host_atlas if container_kind == host_kind else download_atlas(container_kind, directory)
        inputs = directory / 'inputs'
        inputs.mkdir(mode=0o700)
        stage_inputs(inputs, snapshot, container_atlas)
        replay(args.runtime, inputs)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError):
        raise SystemExit('Isolated migration verification failed; raw diagnostics suppressed.') from None
