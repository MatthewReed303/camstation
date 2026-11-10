#!/usr/bin/env bash
# Downloads the CamStation build of the go2rtc engine and verifies each file
# against SHA-256 digests pinned here.
#
# Source: github.com/MatthewReed303/go2rtc, branch `camstation` (go2rtc
# v1.9.15 + Android 11+ WebRTC fix + DVRIP main-stream fix), released by its
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
TAG="camstation-1.9.15.3"
BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

# asset → sha256 (from the release's SHA256SUMS, verified when pinned)
sha_for() {
  case "$1" in
    go2rtc_android_arm64)      echo 5b4e38a7a95538b6f60f462f3783aa693e3bebe60c081ba378a3de2b021a1e76 ;;
    go2rtc_linux_amd64)        echo 5b74541e3b5e67ff775c3ea3bbe722e36edee158ed6add57897d65c64813a2fb ;;
    go2rtc_linux_arm)          echo 0761333a7bb39c418adee6e41b2e676ec878151aa78e1eeb8fc21c90e30a01bd ;;
    go2rtc_linux_arm64)        echo 2b05c2e1a2aa4f308f29a74f35eef3d33b0f43c0e0e3d195574241ef15f3f247 ;;
    go2rtc_windows_amd64.exe)  echo 4aa4ccb8b150453fea654c1dafe415d6679db92091f91fe5f42b6b3317b99bf0 ;;
    go2rtc_windows_arm64.exe)  echo dd7b8bbdc37c4a46216b20a25c85265f6e6311e32b20267a6e75e567c56f5432 ;;
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
