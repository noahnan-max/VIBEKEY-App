#!/usr/bin/env python3
"""Prepare two isolated signed Apps and a loopback feed. No production config."""
from pathlib import Path
import argparse
import json
import os
import plistlib
import re
import socket
import subprocess
import sys
import uuid
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bad-signature', action='store_true')
parser.add_argument('--quiet', action='store_true')
args = parser.parse_args()
base = Path.home() / 'Library/Caches/Vibekey/OwnedProbes' / ('update-acceptance-' + uuid.uuid4().hex[:10])
base.mkdir(parents=True, mode=0o700)
server = base / 'server'; server.mkdir()
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
dependency = ROOT / '.build/dependencies/Sparkle-2.10.0'
key_script = base / 'make-test-key.swift'
key_script.write_text('''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let path = URL(fileURLWithPath: CommandLine.arguments[1])
try key.rawRepresentation.base64EncodedData().write(to: path, options: .atomic)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
print(key.publicKey.rawRepresentation.base64EncodedString())
''')
seed = base / 'fixture-private-seed'
public_key = subprocess.check_output(['swift', str(key_script), str(seed)], text=True).strip()
binary = base / 'VibekeyUpdateAcceptance'
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-target', 'arm64-apple-macosx13.3',
                '-F', str(dependency), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
                str(ROOT / 'Sources/Vibekey/Stores/AppUpdateStore.swift'), str(ROOT / 'tools/UpdateAcceptanceApp.swift'), '-o', str(binary)], check=True)
identifier = 'io.github.noahnan-max.VIBEKEY.UpdateAcceptance.' + base.name.rsplit('-', 1)[1]
app_name = 'VIBEKEY Update Acceptance.app'
for version, directory in [('1', base / 'host'), ('2', base / 'payload')]:
    app = directory / app_name
    (app / 'Contents/MacOS').mkdir(parents=True)
    (app / 'Contents/Frameworks').mkdir()
    subprocess.run(['ditto', str(binary), str(app / 'Contents/MacOS/VibekeyUpdateAcceptance')], check=True)
    subprocess.run(['ditto', str(dependency / 'Sparkle.framework'), str(app / 'Contents/Frameworks/Sparkle.framework')], check=True)
    info = {'CFBundleExecutable': 'VibekeyUpdateAcceptance', 'CFBundleIdentifier': identifier,
            'CFBundleName': 'VIBEKEY 更新验收', 'CFBundleDisplayName': 'VIBEKEY 更新验收',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': version, 'CFBundleShortVersionString': version,
            'NSPrincipalClass': 'NSApplication', 'LSMinimumSystemVersion': '13.3', 'FixtureDirectory': str(base),
            'SUFeedURL': f'http://127.0.0.1:{port}/appcast.xml', 'SUPublicEDKey': public_key,
            'SUEnableAutomaticChecks': args.quiet, 'SUAllowsAutomaticUpdates': False, 'SUAutomaticallyUpdate': False,
            'SUEnableSystemProfiling': False, 'SUVerifyUpdateBeforeExtraction': True, 'SURequireSignedFeed': True,
            'SUSignedFeedFailureExpirationInterval': 0, 'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}}
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run([sys.executable, str(ROOT / 'script/sign_bundle.py'), str(app)], check=True, capture_output=True)
archive = server / 'fixture-2.zip'
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(base / 'payload' / app_name), str(archive)], check=True)
tool = dependency / 'bin/sign_update'
signature = subprocess.check_output([str(tool), '--ed-key-file', str(seed), '-p', str(archive)], text=True).strip()
assert re.fullmatch(r'[A-Za-z0-9+/]{86}==', signature)
if args.bad_signature:
    signature = ('A' if signature[0] != 'A' else 'B') + signature[1:]
feed = server / 'appcast.xml'
feed.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>VIBEKEY isolated acceptance</title><item>
<title>版本 2 · 签名更新验收</title><sparkle:version>2</sparkle:version><sparkle:shortVersionString>2</sparkle:shortVersionString>
<description sparkle:format="plain-text"><![CDATA[本次更新内容：\n• 验证用户确认后下载、签名校验、替换和重开。\n• 只更新此测试 App，不连接硬件、不访问个人配置。]]></description>
<enclosure url="http://127.0.0.1:{port}/fixture-2.zip" sparkle:edSignature="{escape(signature)}" length="{archive.stat().st_size}" type="application/octet-stream"/>
</item></channel></rss>''')
subprocess.run([str(tool), '--ed-key-file', str(seed), str(feed)], check=True, capture_output=True)
result = {'directory': str(base), 'host': str(base / 'host' / app_name), 'port': port,
          'serverDirectory': str(server), 'badSignature': args.bad_signature, 'productionAccess': False}
(base / 'fixture.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result))
