#!/usr/bin/env python3
from pathlib import Path
import json
import plistlib
import sys

ROOT = Path(__file__).resolve().parents[1]
version = json.loads((ROOT / 'release/version.json').read_text())
updates = json.loads((ROOT / 'release/update-config.json').read_text())
info = {
    'CFBundleExecutable': 'Vibekey', 'CFBundleIdentifier': 'io.github.noahnan-max.VIBEKEY',
    'CFBundleName': 'VIBEKEY', 'CFBundleDisplayName': 'VIBEKEY', 'CFBundleIconFile': 'VIBEKEY.icns',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version['version'],
    'CFBundleVersion': version['build'], 'LSMinimumSystemVersion': version['minimumSystemVersion'],
    'NSPrincipalClass': 'NSApplication',
    'CFBundleDevelopmentRegion': 'zh-Hans', 'CFBundleLocalizations': ['zh-Hans'],
    'NSAppleEventsUsageDescription': 'VIBEKEY 按你配置的硬件快捷键和工作流控制本地应用。',
    'SUFeedURL': updates['feedURL'], 'SUPublicEDKey': updates['publicEDKey'],
    'SUEnableAutomaticChecks': True, 'SUScheduledCheckInterval': 86400,
    'SUAutomaticallyUpdate': False, 'SUAllowsAutomaticUpdates': False,
    'SUEnableSystemProfiling': False, 'SUShowReleaseNotes': True,
    'SUVerifyUpdateBeforeExtraction': True, 'SURequireSignedFeed': True,
    'SUSignedFeedFailureExpirationInterval': 0, 'SUEnableJavaScript': False,
}
Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
