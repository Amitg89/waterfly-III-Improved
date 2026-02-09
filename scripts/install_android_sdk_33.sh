#!/usr/bin/env bash
# Install or reinstall Android SDK Platform 33 (required by open_file_plus).
# Run if you see: "Failed to find target 'android-33'" or
# "Failed to transform android.jar" / "PlatformAttrTransform".
# Requires: ANDROID_HOME or ANDROID_SDK_ROOT set (e.g. by Android Studio).

set -e

# Default SDK path on macOS
if [[ -z "$ANDROID_HOME" && -z "$ANDROID_SDK_ROOT" ]]; then
  if [[ -d "$HOME/Library/Android/sdk" ]]; then
    export ANDROID_HOME="$HOME/Library/Android/sdk"
  else
    echo "ANDROID_HOME / ANDROID_SDK_ROOT not set and $HOME/Library/Android/sdk not found."
    echo "Set ANDROID_HOME to your Android SDK path, or install Android Studio."
    exit 1
  fi
fi
SDK="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"

# Prefer cmdline-tools if present
if [[ -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]]; then
  sdkmanager="$SDK/cmdline-tools/latest/bin/sdkmanager"
elif [[ -x "$SDK/tools/bin/sdkmanager" ]]; then
  sdkmanager="$SDK/tools/bin/sdkmanager"
else
  echo "sdkmanager not found under $SDK"
  echo "Install Android SDK Command-line Tools via Android Studio:"
  echo "  SDK Manager -> SDK Tools -> Android SDK Command-line Tools"
  exit 1
fi

PLATFORM_DIR="$SDK/platforms/android-33"
if [[ -d "$PLATFORM_DIR" ]]; then
  echo "Removing existing android-33 (reinstall to fix transform errors)..."
  rm -rf "$PLATFORM_DIR"
fi

echo "Installing Android SDK Platform 33..."
"$sdkmanager" "platforms;android-33"
echo "Done. Run: flutter clean && flutter build apk --debug"
