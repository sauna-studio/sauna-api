#!/usr/bin/env python3
"""Build/run a loopback-only local API using Apple's container CLI.

No credential files are loaded, and build input is limited to the Swift package
and Sources. The script never stops or deletes an unlabelled/foreign container.
"""
import argparse
import json
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAME = 'sauna-api-local'
IMAGE = 'sauna-api:local'
LABEL = 'studio.sauna.project'
OWNER = 'sauna-api-local'


def run(args, capture=False):
    result = subprocess.run(args, text=True, capture_output=capture)
    if result.returncode:
        raise RuntimeError('Command failed: ' + ' '.join(args[:3]))
    return result.stdout if capture else None


def parse_port(value):
    if not re.fullmatch(r'[0-9]{1,5}', value) or not 1 <= int(value) <= 65535:
        raise argparse.ArgumentTypeError('port must be an ASCII integer in 1...65535')
    return int(value)


def stage_context(destination, root=ROOT):
    sources = [root / name for name in ['Containerfile.local', 'Package.swift', 'Package.resolved', 'Sources', 'Tests']]
    for source in sources:
        if not source.exists() or source.is_symlink():
            raise ValueError('Missing or symlinked build input: ' + source.name)
        for path in [source, *source.rglob('*')] if source.is_dir() else [source]:
            if path.is_symlink() or path.suffix.lower() in {'.key', '.pem', '.p8', '.p12'} or path.name == '.env' or path.name.startswith('.env.'):
                raise ValueError('Refusing credential-like or symlinked build input')
    for source in sources:
        target = destination / source.name
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)


def inspect_owned():
    result = subprocess.run(['container', 'inspect', NAME], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('Local API container is unavailable; check container system status')
    items = json.loads(result.stdout)
    if len(items) != 1 or items[0]['configuration']['id'] != NAME or items[0]['configuration'].get('labels', {}).get(LABEL) != OWNER:
        raise RuntimeError('Refusing to operate on a foreign container')
    return items[0]


def start_command(port):
    return ['container', 'run', '--platform', 'linux/arm64', '--detach', '--name', NAME,
            '--label', f'{LABEL}={OWNER}', '--cpus', '2', '--memory', '512M', '--read-only', '--tmpfs', '/tmp',
            '--cap-drop', 'ALL', '--user', '10001:10001', '--publish', f'127.0.0.1:{port}:8080',
            '--env', 'BIND_HOST=0.0.0.0', '--env', 'PORT=8080', IMAGE]


def smoke(port):
    for path in ('health', 'version'):
        deadline = time.monotonic() + 20
        while True:
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/{path}', timeout=2) as response:
                    if response.status != 200 or response.headers.get_content_type() != 'application/json' or response.headers.get('Server') is not None:
                        raise RuntimeError('Unexpected public response headers')
                    data = json.load(response)
                break
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                if time.monotonic() >= deadline:
                    raise RuntimeError('Local API did not become ready') from None
                time.sleep(0.2)
        if path == 'health':
            assert data == {'status': 'ok'}, 'Unexpected health contract'
        else:
            assert set(data) == {'apiVersion', 'version'}, 'Unexpected version fields'
            assert all(isinstance(v, str) and re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', v) for v in data.values()), 'Invalid public release'
        print(f'GET /{path}: 200; public contract verified')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['build', 'start', 'smoke', 'status', 'logs', 'stop', 'remove'])
    parser.add_argument('--port', type=parse_port, default=8080)
    args = parser.parse_args()
    if shutil.which('container') is None:
        raise RuntimeError('Apple container CLI is required')
    if args.action == 'build':
        with tempfile.TemporaryDirectory(prefix='sauna-api-context-') as tmp:
            context = Path(tmp)
            stage_context(context)
            # Avoid 4 GiB: the SwiftSyntax/macro build made that guest unresponsive.
            run(['container', 'build', '--platform', 'linux/arm64', '--cpus', '4', '--memory', '8G', '--progress', 'plain', '--file', str(context / 'Containerfile.local'), '--tag', IMAGE, str(context)])
    elif args.action == 'start':
        # CLI refuses name collisions; never replace an existing container.
        run(start_command(args.port))
    elif args.action == 'smoke':
        smoke(args.port)
    else:
        item = inspect_owned()
        if args.action == 'status':
            print(json.dumps({'name': NAME, 'state': item['status']['state'], 'platform': item['configuration']['platform']}))
        elif args.action == 'logs':
            run(['container', 'logs', '-n', '50', NAME])
        elif args.action == 'stop':
            run(['container', 'stop', '--signal', 'SIGTERM', '--time', '10', NAME])
        elif args.action == 'remove':
            if item['status']['state'] == 'running':
                raise RuntimeError('Stop the local API before removing its container')
            run(['container', 'delete', NAME])


if __name__ == '__main__':
    main()
