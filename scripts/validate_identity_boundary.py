#!/usr/bin/env python3
"""Reproduce external-module identity forgery rejection against the current built identity target."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    subprocess.run(['swift', 'build', '--target', 'SaunaAPIIdentity', '--force-resolved-versions'], cwd=ROOT, capture_output=True, text=True, check=True, timeout=120)
    result = subprocess.run(['swift', 'build', '--show-bin-path'], cwd=ROOT, capture_output=True, text=True, check=True, timeout=60)
    lines = result.stdout.strip().splitlines()
    if not lines:
        raise RuntimeError('Swift build did not report an artifact directory')
    binary = Path(lines[-1])
    modules = next((p for p in [binary, binary / 'Modules'] if (p / 'SaunaAPIIdentity.swiftmodule').exists()), None)
    if modules is None:
        raise RuntimeError('Build the identity module before running the boundary check')
    probes = [
        ('control', 'import Foundation\nimport SaunaAPIIdentity\nfunc identity(_ value: VerifiedSubject) -> UUID { value.userID }\n', None),
        ('constructor', 'import Foundation\nimport SaunaAPIIdentity\nlet subject = VerifiedSubject(userID: UUID())\n', ('initializer', 'inaccessible', 'internal')),
        ('decoding', 'import Foundation\nimport SaunaAPIIdentity\nfunc decode(_ data: Data) throws { _ = try JSONDecoder().decode(VerifiedSubject.self, from: data) }\n', ('Decodable',)),
    ]
    with tempfile.TemporaryDirectory(prefix='sauna-identity-probe-') as temporary:
        for name, source, reason in probes:
            path = Path(temporary) / (name + '.swift')
            path.write_text(source)
            compiled = subprocess.run(['swiftc', '-swift-version', '6', '-typecheck', '-I', str(modules), str(path)], capture_output=True, text=True, timeout=60)
            if reason is None:
                if compiled.returncode:
                    raise RuntimeError('Public identity type control did not compile')
            elif compiled.returncode == 0 or not all(marker in compiled.stderr for marker in reason):
                raise RuntimeError('Identity forgery was not rejected for the expected access/type reason')
    print('External identity type access succeeds; initializer and JSON decoding are rejected')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit('Identity boundary verification failed; compiler diagnostics suppressed.') from None
