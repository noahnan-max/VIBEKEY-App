#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VIBEKEY_SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p .build/manual
swiftc -swift-version 5 -sdk "$VIBEKEY_SDK" -target arm64-apple-macosx13.3 \
  -module-cache-path .build/manual/module-cache \
  -emit-library -static -emit-module -enable-testing -module-name VibekeyCore \
  Sources/VibekeyCore/*.swift -o .build/manual/libVibekeyCore.a \
  -emit-module-path .build/manual/VibekeyCore.swiftmodule
swiftc -swift-version 5 -sdk "$VIBEKEY_SDK" -target arm64-apple-macosx13.3 \
  -module-cache-path .build/manual/module-cache -I .build/manual -L .build/manual \
  -lVibekeyCore Sources/VibekeyProbe/main.swift -o .build/manual/vibekey-probe
