#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/run_hardware_checks.py
python3 tools/run_battery_checks.py
python3 tools/run_codex_desktop_status_checks.py
python3 -m unittest discover -s tools -p 'test_agent_signal_bridge*.py'
python3 tools/run_public_feature_checks.py
python3 tools/run_smart_configuration_http.py
