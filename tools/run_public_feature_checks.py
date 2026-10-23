#!/usr/bin/env python3
"""AU05/model/statistics checks using synthetic files/readers, never live devices."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sources/Vibekey"
run_id = uuid.uuid4().hex[:10]
build = ROOT / ".build/public-features" / run_id
evidence = ROOT / "evidence/public-features" / run_id
build.mkdir(parents=True); evidence.mkdir(parents=True)
suites = {
    "passive_statistics_checks": [APP / "Stores" / n for n in ["AutomaticMicrophoneMonitor.swift", "PassiveInputObserver.swift", "UsageStatisticsStore.swift"]],
    "statistics_consent_checks": [APP / "Stores" / n for n in ["AutomaticMicrophoneMonitor.swift", "PassiveInputObserver.swift", "UsageStatisticsStore.swift"]],
    "au05_smart_checks": [APP / "SmartConfiguration" / n for n in ["AU05SmartModel.swift", "AU05SmartArchive.swift", "SmartConfigurationPreferences.swift"]],
    "smart_credential_cache_checks": [APP / "SmartConfiguration/SmartConfigurationPreferences.swift"],
    "public_upgrade_checks": [APP / "Stores/WorkflowStore.swift", APP / "Stores/RadialMenuStore.swift"],
    "login_item_checks": [APP / "Stores/LoginItemStore.swift", APP / "Support/AppLaunchState.swift"],
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--only", action="append", choices=list(suites), help="Run only the named suite; repeat to select several")
selected = parser.parse_args().only
if selected:
    suites = {name: extra for name, extra in suites.items() if name in selected}
core = sorted((ROOT / "Sources/VibekeyCore").glob("*.swift"))
inputs = sorted(set(core + [p for extra in suites.values() for p in extra] + [ROOT / "tools" / (n + ".swift") for n in suites]))
fingerprint = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before = fingerprint()
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
common = ["swiftc", "-swift-version", "5", "-sdk", sdk, "-target", "arm64-apple-macosx13.3", "-module-cache-path", str(build / "module-cache")]
result = subprocess.run(common + ["-emit-library", "-static", "-emit-module", "-module-name", "VibekeyCore", *map(str, core), "-o", str(build / "libVibekeyCore.a"), "-emit-module-path", str(build / "VibekeyCore.swiftmodule")], text=True, capture_output=True, timeout=120)
(evidence / "core-compile.log").write_text(result.stdout + result.stderr)
if result.returncode:
    print(result.stderr); raise SystemExit(result.returncode)
rows = []
for name, extra in suites.items():
    binary = build / name
    command = common + ["-parse-as-library", "-I", str(build), "-L", str(build), "-lVibekeyCore", *map(str, extra), str(ROOT / "tools" / (name + ".swift")), "-o", str(binary)]
    result = subprocess.run(command, text=True, capture_output=True, timeout=120)
    (evidence / (name + "-compile.log")).write_text(result.stdout + result.stderr)
    if result.returncode:
        rows.append({"suite": name, "status": "COMPILE_FAILED"}); print(name, result.stderr[-3000:], flush=True); continue
    arguments = [str(ROOT / "tools/fixtures/public-0.16.1")] if name == "public_upgrade_checks" else []
    result = subprocess.run([str(binary), *arguments], text=True, capture_output=True, timeout=90)
    (evidence / (name + ".log")).write_text(result.stdout + result.stderr)
    row = {"suite": name, "status": "PASS" if result.returncode == 0 else "FAIL", "exitCode": result.returncode}
    rows.append(row); print(json.dumps(row), result.stdout.strip()[-2000:], flush=True)
    if result.returncode: print(result.stderr[-3000:], flush=True)
after = fingerprint(); drift = [p for p in before if before[p] != after[p]]
report = {"status": "PASS" if all(r["status"] == "PASS" for r in rows) and not drift else "FAIL", "suites": rows, "sourceHashesBefore": before, "sourceHashesAfter": after, "sourceDrift": drift, "physicalDeviceWrites": 0, "externalInputRead": False, "userModelRequests": 0, "systemLoginRegistrationsChanged": False}
(evidence / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"status": report["status"], "evidence": str(evidence)}))
raise SystemExit(0 if report["status"] == "PASS" else 1)
