#!/usr/bin/env python3
"""Fetch one pinned official Sparkle distribution; never installs or launches it."""
from pathlib import Path
import hashlib
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = '2.10.0'
SHA256 = 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
URL = f'https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/Sparkle-{VERSION}.tar.xz'

def ensure():
    cache = ROOT / '.build/dependencies'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f'Sparkle-{VERSION}.tar.xz'
    if not archive.exists():
        temporary = archive.with_suffix('.download')
        with urllib.request.urlopen(URL, timeout=60) as response:
            temporary.write_bytes(response.read())
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != SHA256:
            raise RuntimeError('Sparkle archive checksum mismatch; download retained, not used.')
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError('Cached Sparkle archive checksum mismatch.')
    destination = cache / f'Sparkle-{VERSION}'
    if not destination.exists():
        with tarfile.open(archive) as stream:
            for item in stream.getmembers():
                if Path(item.name).is_absolute() or '..' in Path(item.name).parts:
                    raise RuntimeError('Unsafe archive member.')
        destination.mkdir()
        subprocess.run(['tar', '-xJf', str(archive), '-C', str(destination)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination / 'Sparkle.framework')], check=True, capture_output=True)
    return destination

if __name__ == '__main__':
    print(ensure())
