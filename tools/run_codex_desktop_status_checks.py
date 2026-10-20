#!/usr/bin/env python3
"""Private synthetic metadata fixtures only; no default inbox or hardware writes."""
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    build = ROOT / '.build/codex-desktop-status' / uuid.uuid4().hex[:10]
    build.mkdir(parents=True, mode=0o700)
    fixtures = build / 'private-fixtures'
    fixtures.mkdir(mode=0o700)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    common = ['swiftc', '-swift-version', '5', '-sdk', sdk, '-target', 'arm64-apple-macosx13.3', '-module-cache-path', str(build / 'module-cache')]
    core = [ROOT / 'Sources/VibekeyCore' / name for name in ['AgentSignal.swift', 'VibekeyPaths.swift', 'CodexDesktopStatus.swift']]
    commands = [common + ['-emit-library', '-static', '-emit-module', '-module-name', 'VibekeyCore', *map(str, core),
                         '-o', str(build / 'libVibekeyCore.a'), '-emit-module-path', str(build / 'VibekeyCore.swiftmodule')],
                common + ['-parse-as-library', '-I', str(build), '-L', str(build), '-lVibekeyCore',
                          str(ROOT / 'Sources/Vibekey/Stores/CodexDesktopStatusReader.swift'), str(ROOT / 'tools/codex_desktop_status_checks.swift'),
                          '-o', str(build / 'checks')]]
    for index, command in enumerate(commands):
        result = subprocess.run(command, text=True, capture_output=True, timeout=120)
        (build / ('compile-' + str(index) + '.log')).write_text(result.stdout + result.stderr)
        if result.returncode:
            print(result.stderr[-6000:])
            return result.returncode
    result = subprocess.run([str(build / 'checks'), '--directory=' + str(fixtures)], text=True, capture_output=True, timeout=90)
    (build / 'checks.json').write_text(result.stdout)
    if result.stderr:
        (build / 'runtime.log').write_text(result.stderr)
    print(result.stdout)
    print(json.dumps({'evidence': str(build / 'checks.json'), 'exitCode': result.returncode}))
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
