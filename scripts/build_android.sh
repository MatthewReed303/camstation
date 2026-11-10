#!/usr/bin/env bash
# Release APK for phones: ONE universal file with arm64-v8a (current phones)
# and armeabi-v7a (older 32-bit phones); Android picks the right one.
#   scripts/build_android.sh            → build/app/outputs/flutter-apk/app-release.apk
#   scripts/build_android.sh --split    → one smaller APK per ABI instead
# Signing: CAMSTATION_KEYSTORE / _KEYSTORE_PASSWORD / _KEY_ALIAS / _KEY_PASSWORD,
# otherwise the debug key is used (fine for sideloading).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/fetch_go2rtc.sh android
split=()
[ "${1:-}" = "--split" ] && split=(--split-per-abi)
flutter build apk --release "${split[@]}" --target-platform android-arm,android-arm64
ls -1 build/app/outputs/flutter-apk/*release*.apk
