#!/usr/bin/env bash
# Portable source build. Local development uses an explicit ad-hoc signature.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:---run}"
case "$MODE" in
  --build-only|--run) ;;
  *) printf '%s\n' 'Usage: ./script/build_and_run.sh [--build-only|--run]' >&2; exit 2 ;;
esac
if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' 'VIBEKEY requires macOS.' >&2; exit 2
fi
if [ "$(uname -m)" != arm64 ]; then
  printf '%s\n' 'This build script targets Apple silicon; Intel builds are not validated.' >&2; exit 2
fi
VIBEKEY_APP_BUNDLE="$ROOT_DIR/dist/VIBEKEY.app"
# Never stop another instance or replace a running bundle.
for VIBEKEY_PID in $(pgrep -x Vibekey || true); do
  VIBEKEY_PROCESS_PATH="$(ps -p "$VIBEKEY_PID" -o comm=)"
  case "$VIBEKEY_PROCESS_PATH" in
    "$VIBEKEY_APP_BUNDLE"/*)
      printf '%s\n' 'This development bundle is running. Quit it normally before rebuilding.' >&2
      exit 1 ;;
  esac
done
bash script/build_core.sh
VIBEKEY_SPARKLE_DIR="$(python3 script/ensure_sparkle.py)"
VIBEKEY_SDK="$(xcrun --sdk macosx --show-sdk-path)"
VIBEKEY_FILES=()
while IFS= read -r path; do VIBEKEY_FILES+=("$path"); done < <(find Sources/Vibekey -name '*.swift' -type f | sort)
swiftc -swift-version 5 -sdk "$VIBEKEY_SDK" -target arm64-apple-macosx13.3 \
  -module-cache-path .build/manual/module-cache -module-name Vibekey \
  -I .build/manual -L .build/manual -lVibekeyCore -F "$VIBEKEY_SPARKLE_DIR" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks "${VIBEKEY_FILES[@]}" -o .build/manual/Vibekey
mkdir -p "$ROOT_DIR/dist"
VIBEKEY_STAGE_ROOT="$(mktemp -d "$ROOT_DIR/dist/.VIBEKEY-build.XXXXXX")"
VIBEKEY_STAGE="$VIBEKEY_STAGE_ROOT/VIBEKEY.app"
mkdir -p "$VIBEKEY_STAGE/Contents/MacOS" "$VIBEKEY_STAGE/Contents/Resources/AgentSignals" "$VIBEKEY_STAGE/Contents/Frameworks"
cp .build/manual/Vibekey "$VIBEKEY_STAGE/Contents/MacOS/Vibekey"
cp Assets/Brand/VIBEKEY-symbol.png Assets/Brand/VIBEKEY.icns LICENSE THIRD_PARTY_NOTICES.md "$VIBEKEY_STAGE/Contents/Resources/"
cp script/agent_signal_bridge.py "$VIBEKEY_STAGE/Contents/Resources/AgentSignals/"
test -s Assets/Devices/au05-3d.png
mkdir -p "$VIBEKEY_STAGE/Contents/Resources/Devices"
cp Assets/Devices/au05-3d.png "$VIBEKEY_STAGE/Contents/Resources/Devices/"
ditto "$VIBEKEY_SPARKLE_DIR/Sparkle.framework" "$VIBEKEY_STAGE/Contents/Frameworks/Sparkle.framework"
cp "$VIBEKEY_SPARKLE_DIR/LICENSE" "$VIBEKEY_STAGE/Contents/Resources/Sparkle-LICENSE.txt"
python3 script/bundle_info.py "$VIBEKEY_STAGE/Contents/Info.plist"
if [ -n "${VIBEKEY_SIGNING_IDENTITY:-}" ]; then
  python3 script/sign_bundle.py "$VIBEKEY_STAGE" --identity "$VIBEKEY_SIGNING_IDENTITY"
else
  printf '%s\n' 'Signing for local development (ad hoc; not Apple notarized).'
  python3 script/sign_bundle.py "$VIBEKEY_STAGE"
fi
codesign --verify --deep --strict "$VIBEKEY_STAGE"
if [ -e "$VIBEKEY_APP_BUNDLE" ]; then
  mkdir -p "$ROOT_DIR/.build/previous-bundles"
  mv "$VIBEKEY_APP_BUNDLE" "$ROOT_DIR/.build/previous-bundles/VIBEKEY-$(date -u +%Y%m%dT%H%M%SZ)-$$.app"
fi
mv "$VIBEKEY_STAGE" "$VIBEKEY_APP_BUNDLE"
rmdir "$VIBEKEY_STAGE_ROOT"
printf 'Built: %s\n' "$VIBEKEY_APP_BUNDLE"
if [ "$MODE" = --run ]; then open "$VIBEKEY_APP_BUNDLE"; fi
