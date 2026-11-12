#!/usr/bin/env python3
"""Verify that the Linux API writes to PostgreSQL 18 over the VM's loopback."""
import argparse
import ipaddress
import json
import platform
import re
import signal
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

import local_integration_db as fixture


API_UID = '10001'
HEADER_CANARY = 'sauna34-private-canary'
HEALTH_PROBE_PATH = '/health?probe=sauna34-query-canary'
EXPORT_RUNTIME = r'''set -euo pipefail
export LC_ALL=C
mkdir /output/lib
cp /app/SaunaAPI /output/SaunaAPI
dependencies=$(ldd /app/SaunaAPI)
if [[ "$dependencies" == *'not found'* ]]; then exit 1; fi
while IFS= read -r path; do
  cp -L "$path" "/output/lib/${path##*/}"
done < <(awk '$2=="=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' <<< "$dependencies")
test -x /output/lib/ld-linux-aarch64.so.1
'''

API_START = r'''set -eu
umask 077
install -m 600 -o 10001 -g 10001 /approved/app-password /tmp/sauna-api-password
printf '%s\n' "$$" > /tmp/sauna-api.pid
# The API image uses Ubuntu's runtime; using the PostgreSQL image's loader
# would mix shared-library versions from two different Linux distributions.
exec setpriv --reuid=10001 --regid=10001 --clear-groups \
  /runtime/lib/ld-linux-aarch64.so.1 --library-path /runtime/lib /runtime/SaunaAPI
'''


def wait_for(test, message):
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(0.25)
    raise RuntimeError(message)


def http_request(container, method, path):
    request = (
        f'{method} {path} HTTP/1.1\r\n'
        'Host: localhost\r\nOrigin: http://localhost:5173\r\n'
        f'X-Sauna-Probe: {HEADER_CANARY}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
    )
    return fixture.command([
        'container', 'exec', '--user', API_UID, container, '/bin/bash', '-ec',
        'exec 3<>/dev/tcp/127.0.0.1/8080; printf %s "$1" >&3; cat <&3',
        'sauna-http', request,
    ], timeout=8)


def health_ready(container, process):
    if process.poll() is not None:
        raise RuntimeError('Linux API stopped before serving HTTP')
    try:
        return http_request(container, 'GET', HEALTH_PROBE_PATH).startswith('HTTP/1.1 200 ')
    except (RuntimeError, subprocess.TimeoutExpired):
        return False


def verify_database(container, response):
    if not response.startswith('HTTP/1.1 200 '):
        raise RuntimeError('Passkey registration options did not return HTTP 200')
    match = re.search(r'"challengeID"\s*:\s*"([a-fA-F0-9-]{36})"', response)
    if match is None:
        raise RuntimeError('Passkey registration options omitted the challenge ID')
    challenge = uuid.UUID(match[1])
    sql = f"""
    SELECT current_setting('server_version_num')::int / 10000,
           current_setting('listen_addresses'),
           (SELECT count(*) FROM public.webauthn_challenges WHERE id = '{challenge}'),
           (SELECT count(*) FROM public.passkey_registration_intents WHERE challenge_id = '{challenge}');
    """
    result = fixture.command([
        'container', 'exec', '--user', 'postgres', container, '/bin/bash', '-ec',
        'for path in /tmp/sauna-integration.*/socket; do '
        'exec psql -h "$path" -U postgres -d sauna_atlas_replay -At -v ON_ERROR_STOP=1 -c "$1"; done',
        'sauna-sql', sql,
    ])
    if result.strip() != '18|127.0.0.1|1|1':
        raise RuntimeError('PostgreSQL 18 did not confirm both rows on loopback')


def network_options(network, collector_ip):
    if network is None:
        return ['--network', 'none'], []
    info = json.loads(fixture.command(['container', 'network', 'inspect', network]))
    if len(info) != 1 or info[0]['configuration']['mode'] != 'hostOnly':
        raise RuntimeError('Collector verification requires a dedicated internal Apple container network')
    ip = ipaddress.IPv4Address(collector_ip)
    if ip not in ipaddress.IPv4Network(info[0]['status']['ipv4Subnet']):
        raise RuntimeError('Collector address is outside the internal Apple container network')
    return ['--network', network], ['-e', f'SAUNA_LOCAL_OTLP_HOST={ip}']


def validate_api_image(image):
    items = json.loads(fixture.command(['container', 'image', 'inspect', image]))
    if len(items) != 1 or not any(
        variant['platform'] == {'architecture': 'arm64', 'os': 'linux'}
        and variant['config']['config'].get('Entrypoint') == ['/app/SaunaAPI']
        and variant['config']['config'].get('User') == '10001:10001'
        for variant in items[0]['variants']
    ):
        raise RuntimeError('Expected a locally built Linux arm64 Sauna API image')


def verify(api_image, network, collector_ip):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('This verification requires Apple container on Apple silicon')
    validate_api_image(api_image)
    net_args, api_export = network_options(network, collector_ip)
    snapshot = fixture.migration_ci.validated_inputs()
    fixture.validate_schema(snapshot['db/schema.sql'])
    fixture.prerequisites.validate_manifest(snapshot['db/postgresql-prerequisites.json'])
    owner = str(uuid.uuid4())
    container = 'sauna-linux-api-db-' + owner
    with tempfile.TemporaryDirectory(prefix='sauna-linux-api-db-') as temporary:
        root = Path(temporary)
        public = root / 'public'
        runtime = root / 'runtime'
        credential = root / 'credential'
        public.mkdir(mode=0o755)
        runtime.mkdir(mode=0o755)
        credential.mkdir(mode=0o700)
        (public / 'schema.sql').write_bytes(snapshot['db/schema.sql'])
        (public / 'start.sh').write_text(fixture.START)
        (public / 'prerequisites-bootstrap.sql').write_text(fixture.prerequisites.BOOTSTRAP_SQL)
        (public / 'prerequisites-verify.sql').write_text(fixture.prerequisites.VERIFY_SQL)

        # Export the Linux runtime without mounting the database credential into the API image.
        fixture.command([
            'container', 'run', '--rm', '--network', 'none', '--read-only', '--user', '0:0',
            '--mount', f'type=bind,source={runtime},target=/output', '--entrypoint', '/bin/bash',
            api_image, '-c', EXPORT_RUNTIME,
        ], timeout=90)
        password = credential / 'app-password'
        fixture.stage_password(fixture.approved_password(), password)
        process = None
        try:
            fixture.command([
                'container', 'run', '--detach', '--rm', '--name', container,
                '--label', f'{fixture.LABEL}={owner}', '--read-only', '--tmpfs', '/tmp',
                '--cpus', '2', '--memory', '768M', '--no-dns', *net_args,
                '--mount', f'type=bind,source={public},target=/input,readonly',
                '--mount', f'type=bind,source={runtime},target=/runtime,readonly',
                '--mount', f'type=bind,source={credential},target=/approved,readonly',
                '--entrypoint', '/bin/sh', fixture.migration_ci.IMAGE,
                '-c', fixture.BOOTSTRAP, 'sauna-db', '127.0.0.1',
            ], timeout=90)
            wait_for(
                lambda: subprocess.run([
                    'container', 'exec', '--user', 'postgres', container,
                    'test', '-f', '/tmp/sauna-integration-ready',
                ], capture_output=True, timeout=8).returncode == 0,
                'PostgreSQL 18 did not become ready',
            )
            process = subprocess.Popen([
                'container', 'exec', '--user', '0:0',
                '-e', 'SAUNA_LOCAL_AUTH=1', '-e', 'BIND_HOST=127.0.0.1', '-e', 'PORT=8080',
                '-e', 'PGHOST=127.0.0.1', '-e', 'PGPORT=5432', '-e', 'PGDATABASE=sauna_atlas_replay',
                '-e', 'PGPASSWORD_FILE=/tmp/sauna-api-password', *api_export,
                container, '/bin/sh', '-ec', API_START,
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            wait_for(lambda: health_ready(container, process), 'Linux API did not become ready')
            password.unlink()
            verify_database(container, http_request(container, 'POST', '/auth/passkeys/registration/options'))
            fixture.command([
                'container', 'exec', '--user', '0:0', container, '/bin/sh', '-ec',
                'kill -TERM "$(cat /tmp/sauna-api.pid)"',
            ])
            if process.wait(timeout=15) != 0:
                raise RuntimeError('Linux API did not exit cleanly on SIGTERM')
            print('Linux API: HTTP 200, PostgreSQL 18 loopback with both registration rows, SIGTERM exit 0.')
        finally:
            try:
                fixture.cleanup(container, owner)
            finally:
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--api-image', default='sauna-api:local', help='Use only a trusted local Containerfile.local build')
    parser.add_argument('--network')
    parser.add_argument('--collector-ip')
    options = parser.parse_args()
    if bool(options.network) != bool(options.collector_ip):
        parser.error('--network and --collector-ip must be set together')
    if not re.fullmatch(r'sauna-api:[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}', options.api_image):
        parser.error('--api-image must name a local Sauna API tag')

    def terminate(_signal, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, terminate)
    try:
        verify(options.api_image, options.network, options.collector_ip)
    except RuntimeError as error:
        raise SystemExit(str(error)) from None
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt):
        raise SystemExit('Linux API verification failed; raw diagnostics suppressed') from None


if __name__ == '__main__':
    main()
