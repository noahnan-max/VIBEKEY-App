#!/usr/bin/env python3
"""Prepare signed release files locally; never publishes or installs anything."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
from datetime import datetime, timezone
from email.utils import format_datetime
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=ROOT/'dist/VIBEKEY.app')
args = parser.parse_args()
version = json.loads((ROOT/'release/version.json').read_text())
config = json.loads((ROOT/'release/update-config.json').read_text())
app = args.app.resolve()
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'io.github.noahnan-max.VIBEKEY'
assert info['CFBundleShortVersionString'] == version['version'] and info['CFBundleVersion'] == version['build']
for field in ['SUAutomaticallyUpdate','SUAllowsAutomaticUpdates','SUEnableSystemProfiling']:
    assert info[field] is False, field
assert info['SURequireSignedFeed'] and info['SUVerifyUpdateBeforeExtraction']
assert info['SUPublicEDKey'] == config['publicEDKey']
assert (app/'Contents/Resources/Devices/au05-3d.png').is_file()
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
tools = ROOT/'.build/dependencies/Sparkle-2.10.0/bin'
key = subprocess.check_output([str(tools/'generate_keys'),'--account',config['keychainAccount'],'-p'],text=True).strip()
assert key == config['publicEDKey'], 'Signing account does not match the key embedded in the App.'
output = ROOT/'dist'/('release-'+version['version'])
if output.exists(): raise SystemExit('Release output exists; preserve it rather than silently replacing signed files.')
output.mkdir()
filename = 'VIBEKEY-'+version['version']+'-AU05-arm64.zip'
archive = output/filename
subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',str(app),str(archive)],check=True)
sign = [str(tools/'sign_update'),'--account',config['keychainAccount']]
signature = subprocess.check_output(sign+['-p',str(archive)],text=True).strip()
assert re.fullmatch(r'[A-Za-z0-9+/]{86}==',signature)
notes = (ROOT/'release'/('notes-'+version['version']+'.txt')).read_text()
feed = output/'appcast.xml'
asset_url = f'https://github.com/noahnan-max/VIBEKEY-App/releases/download/v{version["version"]}/{filename}'
feed.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>VIBEKEY AU05 updates</title><link>https://github.com/noahnan-max/VIBEKEY-App/releases</link>
<description>Signed AU05 releases with user-confirmed installation.</description>
<item><title>VIBEKEY {escape(version['version'])}</title>
<link>https://github.com/noahnan-max/VIBEKEY-App/releases/tag/v{escape(version['version'])}</link>
<pubDate>{format_datetime(datetime.now(timezone.utc),usegmt=True)}</pubDate>
<sparkle:version>{escape(version['build'])}</sparkle:version>
<sparkle:shortVersionString>{escape(version['version'])}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>{escape(version['minimumSystemVersion'])}</sparkle:minimumSystemVersion>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<description sparkle:format="plain-text">{escape(notes)}</description>
<enclosure url="{escape(asset_url)}" sparkle:edSignature="{signature}" length="{archive.stat().st_size}" type="application/octet-stream"/>
</item></channel></rss>''')
subprocess.run(sign+[str(feed)],check=True,capture_output=True)
subprocess.run(sign+['--verify',str(archive),signature],check=True,capture_output=True)
subprocess.run(sign+['--verify',str(feed)],check=True,capture_output=True)
files=[archive,feed]
(output/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in files))
manifest={'version':version['version'],'build':version['build'],'archive':filename,'bytes':archive.stat().st_size,
          'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'feedSHA256':hashlib.sha256(feed.read_bytes()).hexdigest(),
          'signedArchive':True,'signedFeed':True,'manualInstallOnly':True,'complete3DArtwork':True,'appleNotarized':False,
          'filesPublished':False,'artifactURL':asset_url}
(output/'release.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest))
