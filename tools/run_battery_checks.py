#!/usr/bin/env python3
"""Build and exercise battery logic using an owned in-memory transport only."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / '.build/battery-agent-manual'
EVIDENCE = ROOT / 'evidence/battery-agent'


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    core = sorted((ROOT / 'Sources/VibekeyCore').glob('*.swift'))
    store = ROOT / 'Sources/Vibekey/Stores/DeviceStore.swift'
    probe = ROOT / 'tools/battery_checks.swift'
    inputs = core + [store, probe]
    hashes = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    before = hashes()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    common = ['swiftc', '-swift-version', '5', '-sdk', sdk, '-target', 'arm64-apple-macosx13.3', '-module-cache-path', str(BUILD / 'module-cache')]
    commands = [
        common + ['-enable-testing', '-emit-library', '-static', '-emit-module', '-module-name', 'VibekeyCore', *map(str, core), '-o', str(BUILD / 'libVibekeyCore.a'), '-emit-module-path', str(BUILD / 'VibekeyCore.swiftmodule')],
        common + ['-parse-as-library', '-I', str(BUILD), '-L', str(BUILD), '-lVibekeyCore', str(store), str(probe), '-o', str(BUILD / 'battery_checks')],
        [str(BUILD / 'battery_checks')],
    ]
    for index, command in enumerate(commands):
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        (EVIDENCE / f'{index}.log').write_text(result.stdout + result.stderr)
        if index == 2:
            try:
                report = json.loads(result.stdout)
                report['sourceHashesBefore'] = before
                report['sourceHashesAfter'] = hashes()
                report['sourceDrift'] = [p for p, digest in before.items() if hashes()[p] != digest]
                if report['sourceDrift']:
                    report['status'] = 'FAIL'
                (EVIDENCE / 'receipt.json').write_text(json.dumps(report, indent=2))
                print(json.dumps({'status': report['status'], 'checks': len(report['checks']), 'failed': [c for c in report['checks'] if not c['pass']], 'evidence': str(EVIDENCE)}))
                return 0 if report['status'] == 'PASS' and result.returncode == 0 else 1
            except json.JSONDecodeError:
                pass
        if result.returncode:
            print(result.stdout[-3000:] + result.stderr[-5000:])
            return result.returncode
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
