#!/usr/bin/env bash
# Downloads the CamStation build of the go2rtc engine and verifies each file
# against SHA-256 digests pinned here.
#
# Source: github.com/MatthewReed303/go2rtc, branch `camstation` (go2rtc
# v1.9.15 + Android 11+ WebRTC fix + DVRIP main-stream fix + voice boost), released by its
# "CamStation engine release" workflow. No UPX (Android 8 can't run it).
#
# Usage: scripts/fetch_go2rtc.sh [target ...]
#   targets: linux_amd64 linux_arm64 linux_arm windows_x64 windows_arm64
#            android = arm64-v8a (Android build) + armeabi-v7a + x86_64 (Linux
#                      builds), installed as android/app/src/main/jniLibs/<abi>/libgo2rtc.so
#   (default: this host)
#
# Works on Linux, macOS and Windows (Git Bash on GitHub Actions).
set -euo pipefail

REPO="MatthewReed303/go2rtc"
TAG="camstation-1.9.15.4"
BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

# asset → sha256 (from the release's SHA256SUMS, verified when pinned)
sha_for() {
  case "$1" in
    go2rtc_android_arm64)      echo 5ff95f0629b192a3f21b6ef316ff676b540276efc016258307ade0cb5fe86a47 ;;
    go2rtc_linux_amd64)        echo e3fcf73ebef691caf44012ff12d816977433120ea8e54e7115fa41b96e6e86f8 ;;
    go2rtc_linux_arm)          echo 21939e20468869d7cdd36a1a34728c226250c674f53c45f6979de3691aa8d438 ;;
    go2rtc_linux_arm64)        echo 2b90b17ef33e89a3e810e2b7843d44b907c81012c2ec57c84af166c2710c0278 ;;
    go2rtc_windows_amd64.exe)  echo 7c773dd27efec87011ea8704b47902454860b007d378b7c1a5b9f6b1b6794b8e ;;
    go2rtc_windows_arm64.exe)  echo f48c93a260074ed6ba8ffa648cba44a20f0f2cf89c3d3fdca36032d16f91dfa7 ;;
    *) echo "unknown asset: $1" >&2; return 1 ;;
  esac
}

# target → "asset destination-relative-to-repo"
dest_for() {
  case "$1" in
    linux_amd64)   echo "go2rtc_linux_amd64 engine_bin/linux_amd64/go2rtc" ;;
    linux_arm64)   echo "go2rtc_linux_arm64 engine_bin/linux_arm64/go2rtc" ;;
    linux_arm)     echo "go2rtc_linux_arm engine_bin/linux_arm/go2rtc" ;;
    windows_x64)   echo "go2rtc_windows_amd64.exe engine_bin/windows_x64/go2rtc.exe" ;;
    windows_arm64) echo "go2rtc_windows_arm64.exe engine_bin/windows_arm64/go2rtc.exe" ;;
    android_arm64-v8a)   echo "go2rtc_android_arm64 android/app/src/main/jniLibs/arm64-v8a/libgo2rtc.so" ;;
    android_armeabi-v7a) echo "go2rtc_linux_arm android/app/src/main/jniLibs/armeabi-v7a/libgo2rtc.so" ;;
    android_x86_64)      echo "go2rtc_linux_amd64 android/app/src/main/jniLibs/x86_64/libgo2rtc.so" ;;
    *) echo "unknown target: $1" >&2; return 1 ;;
  esac
}

host_target() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
  case "$os" in
    Linux) echo "linux_${arch}" ;;
    MINGW*|MSYS*|CYGWIN*) [ "$arch" = arm64 ] && echo windows_arm64 || echo windows_x64 ;;
    *) echo "no engine build for $os/$arch" >&2; return 1 ;;
  esac
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${ROOT}/engine_bin/.download/${TAG}"
mkdir -p "$CACHE"

targets=()
for t in "${@:-$(host_target)}"; do
  if [ "$t" = android ]; then
    targets+=(android_arm64-v8a android_armeabi-v7a android_x86_64)
  else
    targets+=("$t")
  fi
done

for t in "${targets[@]}"; do
  read -r asset dest <<<"$(dest_for "$t")"
  want="$(sha_for "$asset")"
  dl="${CACHE}/${asset}"
  if [ ! -f "$dl" ] || [ "$(sha256 "$dl")" != "$want" ]; then
    echo "→ downloading ${asset} (${TAG})"
    curl -fsSL --retry 3 -o "${dl}.part" "${BASE_URL}/${asset}"
    mv "${dl}.part" "$dl"
  fi
  got="$(sha256 "$dl")"
  if [ "$got" != "$want" ]; then
    rm -f "$dl"
    echo "✗ SHA-256 mismatch for ${asset}: got ${got}, want ${want}" >&2
    exit 1
  fi
  mkdir -p "$(dirname "${ROOT}/${dest}")"
  cp "$dl" "${ROOT}/${dest}"
  chmod +x "${ROOT}/${dest}"
  echo "✓ ${t}: ${dest} (sha256 verified)"
done
