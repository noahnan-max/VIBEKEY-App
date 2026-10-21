#!/usr/bin/env python3
"""Sign known Sparkle components inside-out, then the host. No --deep signing."""
from pathlib import Path
import argparse
import subprocess

def sign(bundle, identity):
    bundle = Path(bundle).resolve()
    framework = bundle / 'Contents/Frameworks/Sparkle.framework'
    version = framework / 'Versions/B'
    expected_apps = {version / 'Updater.app'}
    actual_apps = {p for p in bundle.rglob('*.app') if not p.is_symlink()}
    if actual_apps != expected_apps:
        raise RuntimeError('Unexpected nested application; refusing to sign.')
    targets = [version / 'XPCServices/Installer.xpc', version / 'XPCServices/Downloader.xpc', version / 'Autoupdate', version / 'Updater.app', framework]
    for target in targets:
        if not target.exists(): raise RuntimeError('Expected Sparkle component is missing.')
        subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', '--options', 'runtime', '--preserve-metadata=entitlements', str(target)], check=True)
    subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(bundle)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--identity', default='-')
    args = parser.parse_args()
    sign(args.bundle, args.identity)
