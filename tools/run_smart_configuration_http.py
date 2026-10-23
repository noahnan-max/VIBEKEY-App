#!/usr/bin/env python3
"""AU05-only loopback HTTP regression. No GUI, credentials or hardware."""
import argparse
import copy
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import subprocess
import threading


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-root", type=Path)
    args = parser.parse_args()
    source = args.source_root.resolve()
    output = (args.output_root or source / "evidence/smart-configuration-http").resolve()
    output.mkdir(parents=True, exist_ok=True)
    build = output / "build"
    build.mkdir(exist_ok=True)
    temporary = output / "tmp"
    temporary.mkdir(exist_ok=True)
    core = sorted((source / "Sources/VibekeyCore").glob("*.swift"))
    model = source / "Sources/Vibekey/SmartConfiguration/AU05SmartModel.swift"
    check = Path(__file__).resolve().with_name("smart_configuration_http_checks.swift")
    inputs = core + [model, check]
    before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    requests = []
    fixture_key = "fixture-only-value-not-a-secret"
    plan = {"summary": "synthetic AU05 plan", "clarification": None,
            "keys": [{"trigger": "key.0", "action": "shortcut", "keyCode": 90, "modifiers": 0}],
            "macros": [], "lighting": None}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 512 * 1024:
                self.send_error(413)
                return
            body = json.loads(self.rfile.read(length))
            match = re.search(r"HTTP_CASE:([a-z-]+)", body["messages"][-1]["content"])
            scenario = match.group(1) if match else "unknown"
            requests.append({"case": scenario, "path": self.path, "model": body.get("model"),
                             "fixtureAuthOnly": self.headers.get("Authorization") == "Bearer " + fixture_key})
            if self.path.startswith("/redirect/"):
                self.send_response(307)
                self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/forbidden/chat/completions")
                self.end_headers()
                return
            expected = "auto" if body.get("model", "").startswith("deepseek") else {
                "type": "function", "function": {"name": "propose_configuration"}}
            status, error = 200, None
            if body.get("tool_choice") != expected:
                status, error = 400, "Unexpected tool choice"
            elif body.get("model", "").startswith("deepseek") and body.get("thinking") != {"type": "disabled"}:
                status, error = 400, "Missing explicit disabled thinking"
            elif scenario == "thinking-conflict":
                status, error = 400, "Thinking mode does not support this tool_choice " + fixture_key
            elif scenario == "schema-error":
                status, error = 400, "Invalid tool function schema " + fixture_key
            elif scenario == "unauthorized":
                status, error = 401, fixture_key
            elif scenario == "opaque-error":
                status, error = 400, fixture_key + " DO_NOT_SURFACE_REQUEST"
            if error:
                payload = json.dumps({"error": {"message": error}}).encode()
            elif scenario == "oversized-response":
                payload = b"x" * (600 * 1024)
            elif scenario == "missing-tool":
                payload = json.dumps({"choices": [{"message": {"content": "No configuration"}}]}).encode()
            else:
                value = copy.deepcopy(plan)
                if scenario == "unknown-root":
                    value["schedule"] = {"every": "day"}
                elif scenario in ("unknown-macro", "unknown-step"):
                    value["keys"] = []
                    value["macros"] = [{"trigger": "key.1", "name": "fixture", "remove": False, "steps": [
                        {"kind": "shortcut", "keyCode": 8, "modifiers": 1048576, "seconds": None, "scrollLines": None}]}]
                    if scenario == "unknown-macro":
                        value["macros"][0]["applicationBundleID"] = "example.invalid"
                    else:
                        value["macros"][0]["steps"][0]["argument"] = "DO_NOT_EXECUTE"
                elif scenario == "unknown-light":
                    value["lighting"] = {"mode": 1, "brightness": 8, "hue": 170}
                elif scenario == "unknown-key":
                    value["keys"][0]["applicationBundleID"] = "example.invalid"
                elif scenario == "boolean-keycode":
                    value["keys"][0]["keyCode"] = True
                call = {"type": "function", "function": {
                    "name": "unapproved_tool" if scenario == "wrong-tool" else "propose_configuration",
                    "arguments": "invalid JSON" if scenario == "invalid-arguments" else json.dumps(value)}}
                payload = json.dumps({"choices": [{"finish_reason": "tool_calls", "message": {
                    "tool_calls": [call, call] if scenario == "two-tools" else [call]}}]}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    environment = dict(os.environ, TMPDIR=str(temporary),
                       VIBEKEY_SMART_FIXTURE_BASE=f"http://127.0.0.1:{server.server_port}")
    report = {"result": "FAIL", "GUIStarted": False, "keychainAccesses": 0,
              "cloudRequests": 0, "physicalDeviceWrites": 0, "sourceHashes": before}
    try:
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        common = ["swiftc", "-swift-version", "5", "-sdk", sdk, "-target", "arm64-apple-macosx13.3",
                  "-module-cache-path", str(build / "module-cache")]
        command = common + ["-emit-library", "-static", "-emit-module", "-enable-testing",
                            "-module-name", "VibekeyCore", *map(str, core),
                            "-o", str(build / "libVibekeyCore.a"),
                            "-emit-module-path", str(build / "VibekeyCore.swiftmodule")]
        for name, command in [("core", command), ("check", common + [
                "-parse-as-library", "-I", str(build), "-L", str(build), "-lVibekeyCore",
                str(model), str(check), "-o", str(build / "smart-configuration-http-checks")])]:
            result = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=120)
            (output / (name + "-compile.log")).write_text(result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError(name + " compilation failed")
        result = subprocess.run([str(build / "smart-configuration-http-checks")], capture_output=True,
                                text=True, env=environment, timeout=90)
        (output / "checks.log").write_text(result.stdout + result.stderr)
        checks = json.loads(result.stdout)
        drift = [str(p) for p in inputs if hashlib.sha256(p.read_bytes()).hexdigest() != before[str(p)]]
        blocked = not any(v["path"].startswith("/forbidden/") for v in requests)
        preflight = not any(v["case"] in ("oversized-request", "cancelled-before-send") for v in requests)
        good = result.returncode == 0 and checks["result"] == "PASS" and blocked and preflight and not drift
        report.update(result="PASS" if good else "FAIL", checks=checks,
                      redirectRequestsBlocked=blocked, rejectedBeforeNetwork=preflight,
                      requests=requests, sourceDrift=drift)
    except Exception as error:
        report["failure"] = str(error)
    finally:
        server.shutdown()
        server.server_close()
    (output / "receipt.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({"result": report["result"], "receipt": str(output / "receipt.json"),
                      "checks": len(report.get("checks", {}).get("checks", [])),
                      "loopbackRequests": len(requests), "GUIStarted": False}))
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
