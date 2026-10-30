#!/usr/bin/env bash
# Downloads a static aria2c for Android and installs it into jniLibs.
#
# Source: abcfy2/aria2-static-build (weekly "continuous" release, musl static
# build; GPLv2). See https://github.com/abcfy2/aria2-static-build
#
# Usage:
#   tool/fetch_aria2_android.sh            # arm64-v8a (most phones)
#   tool/fetch_aria2_android.sh armeabi-v7a
#   tool/fetch_aria2_android.sh x86_64     # emulators
#
# Override the download URL (e.g. a pinned release) with ARIA2_ZIP_URL.
set -euo pipefail

ABI=${1:-arm64-v8a}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

case "$ABI" in
  arm64-v8a)
    ASSET="aria2-aarch64-linux-musl_static.zip"
    ;;
  armeabi-v7a)
    ASSET="aria2-armv7-linux-musleabihf_static.zip"
    ;;
  x86_64)
    ASSET="aria2-x86_64-linux-musl_static.zip"
    ;;
  *)
    echo "Unsupported ABI: $ABI (use arm64-v8a, armeabi-v7a or x86_64)" >&2
    exit 64
    ;;
esac

URL=${ARIA2_ZIP_URL:-"https://github.com/abcfy2/aria2-static-build/releases/download/continuous/$ASSET"}

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 69; }
command -v unzip >/dev/null 2>&1 || { echo "unzip is required" >&2; exit 69; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL"
curl -fL --retry 2 --connect-timeout 20 -o "$TMP/aria2.zip" "$URL"

unzip -q "$TMP/aria2.zip" -d "$TMP/out"
BINARY=$(find "$TMP/out" -type f -name 'aria2c' | head -n 1)
if [[ -z "${BINARY:-}" ]]; then
  BINARY=$(find "$TMP/out" -type f -name 'aria2c*' | head -n 1)
fi
if [[ -z "${BINARY:-}" ]]; then
  echo "No aria2c binary found in the archive. Contents:" >&2
  ls -la "$TMP/out" >&2
  exit 66
fi

"$ROOT/tool/package_aria2_android.sh" "$BINARY" "$ABI"

cat <<EOF

Done. Notes for Android:
  * Static musl build works on bionic devices; no extra .so files needed.
  * Kazumi starts aria2 with --async-dns-server=223.5.5.5,1.1.1.1 because
    Android has no /etc/resolv.conf.
  * .torrent URLs are downloaded by the app itself (system CA store), so
    aria2 does not need a CA bundle.
  * aria2 is GPLv2; keep the corresponding source available if you distribute
    an APK containing this binary.
EOF
