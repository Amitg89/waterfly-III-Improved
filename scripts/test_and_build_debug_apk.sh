#!/usr/bin/env bash
# Test and build debug APK for Waterfly III (Phase 1 changes).
# Run from project root: ./scripts/test_and_build_debug_apk.sh
# Requires: Flutter in PATH (or set FLUTTER_ROOT).

set -e
cd "$(dirname "$0")/.."

FLUTTER="${FLUTTER:-flutter}"
if ! command -v "$FLUTTER" >/dev/null 2>&1; then
  if [[ -n "$FLUTTER_ROOT" ]]; then
    FLUTTER="$FLUTTER_ROOT/bin/flutter"
  fi
  if ! command -v "$FLUTTER" >/dev/null 2>&1; then
    echo "Flutter not found. Install Flutter or set FLUTTER_ROOT / add flutter to PATH."
    exit 1
  fi
fi

echo "=== Flutter version ==="
"$FLUTTER" --version

echo ""
echo "=== Analyzing project ==="
"$FLUTTER" analyze lib/

echo ""
echo "=== Running tests ==="
"$FLUTTER" test test/ || true

echo ""
echo "=== Building debug APK ==="
"$FLUTTER" build apk --debug

APK="build/app/outputs/flutter-apk/app-debug.apk"
if [[ -f "$APK" ]]; then
  echo ""
  echo "=== Debug APK ready ==="
  echo "  $APK"
  echo "  Install on device: adb install -r $APK"
else
  echo "APK not found at $APK"
  exit 1
fi
