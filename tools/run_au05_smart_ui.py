#!/usr/bin/env python3
"""Receiver-operated AU05 native fixture. Requires explicit --launch."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import subprocess
import threading
import time
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--app", type=Path)
    parser.add_argument("--launch", action="store_true", help="Explicitly launch the isolated native fixture")
    args = parser.parse_args()
    if not args.launch:
        parser.error("--launch is required; this runner starts a GUI process")
    root = args.source_root.resolve()
    app = (args.app or root / "dist/VIBEKEY.app").resolve()
    if not app.is_relative_to((root / "dist").resolve()):
        parser.error("The test app must be inside this source checkout's dist directory")
    preference_source = (root / "Sources/Vibekey/SmartConfiguration/SmartConfigurationPreferences.swift").read_text()
    if "guard hasSavedSettings" not in preference_source:
        parser.error("Fresh-config Keychain guard is required; rebuild the app after adding it")
    binary = app / "Contents/MacOS/Vibekey"
    critical = [root / "Sources/Vibekey/SmartConfiguration/SmartConfigurationPreferences.swift",
                root / "Sources/Vibekey/SmartConfiguration/AU05SmartUIProbe.swift",
                root / "Sources/Vibekey/Support/VibekeyUIProbe.swift"]
    if binary.stat().st_mtime < max(p.stat().st_mtime for p in critical):
        parser.error("Rebuild the fixture app after installing the guard, probe and dispatch")
    metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    probe = Path.home() / "Library/Caches/Vibekey/OwnedProbes" / ("au05-public-smart-" + uuid.uuid4().hex[:10])
    probe.mkdir(parents=True, mode=0o700)
    requests = []
    canary = "FIXTURE_PRIVATE_MACRO_NEVER_UPLOAD"
    fixture_key = "fixture-only-value-not-a-secret"

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 512 * 1024:
                self.send_error(413)
                return
            raw = self.rfile.read(length)
            body = json.loads(raw)
            text = body["messages"][-1]["content"]
            connection = "connection_test" in text
            safe = canary not in json.dumps(body) and self.headers.get("Authorization") == "Bearer " + fixture_key
            requests.append({"connectionTest": connection, "privateMacroExcluded": canary not in json.dumps(body),
                             "fixtureAuthOnly": self.headers.get("Authorization") == "Bearer " + fixture_key})
            if not safe:
                self.send_error(400)
                return
            plan = {"summary": "Synthetic connection test" if connection else "Synthetic AU05 configuration",
                    "clarification": "Connection test complete" if connection else None,
                    "keys": [], "macros": [], "lighting": None}
            if not connection:
                plan.update(keys=[{"trigger": "key.0", "action": "shortcut", "keyCode": 90, "modifiers": 0}],
                            macros=[{"trigger": "key.1", "name": "Synthetic copy and paste", "remove": False, "steps": [
                                {"kind": "shortcut", "keyCode": 8, "modifiers": 1048576, "seconds": None, "scrollLines": None},
                                {"kind": "delay", "keyCode": None, "modifiers": None, "seconds": 0.3, "scrollLines": None},
                                {"kind": "shortcut", "keyCode": 9, "modifiers": 1048576, "seconds": None, "scrollLines": None}]}],
                            lighting={"mode": 1, "brightness": 8})
            payload = json.dumps({"choices": [{"finish_reason": "tool_calls", "message": {"tool_calls": [
                {"type": "function", "function": {"name": "propose_configuration", "arguments": json.dumps(plan)}}]}}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(["open", "-n", str(app), "--args", "--ui-probe",
                        "--probe-directory=" + str(probe), "--au05-smart-probe",
                        "--smart-fixture-base=http://127.0.0.1:" + str(server.server_port)], check=True)
        receipt = probe / "au05-smart-receipt.json"
        deadline = time.monotonic() + 90
        while not receipt.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        report = json.loads(receipt.read_text()) if receipt.exists() else {"result": "NOT_COMPLETED"}
        valid = (report.get("result") == "PASS_AU05_NATIVE_LOOPBACK_SYNTHETIC_TRANSACTION"
                 and len(requests) == 2 and all(v["privateMacroExcluded"] and v["fixtureAuthOnly"] for v in requests))
        report.update(binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                      appVersion=metadata["CFBundleShortVersionString"], probeDirectory=str(probe),
                      loopbackRequests=requests, receiverResult="PASS" if valid else "FAIL")
        (probe / "runner-receipt.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
        return 0 if valid else 1
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
