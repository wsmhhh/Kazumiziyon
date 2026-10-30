#!/usr/bin/env bash
# Packages a static aria2c binary for Android as a jniLibs entry.
#
# Android 10+ forbids executing files in the app data directory, but files in
# nativeLibraryDir are executable. Naming the binary libaria2c.so makes the
# Android build system extract it there automatically.
#
# Usage:
#   tool/package_aria2_android.sh /path/to/aria2c arm64-v8a
#   tool/package_aria2_android.sh /path/to/aria2c armeabi-v7a
#   tool/package_aria2_android.sh /path/to/aria2c x86_64
#
# The binary must be cross-compiled for the given ABI. Verify with:
#   file /path/to/aria2c        # e.g. "ELF 64-bit LSB pie executable, ARM aarch64"
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <aria2c-binary> <arm64-v8a|armeabi-v7a|x86_64>" >&2
  exit 64
fi

BINARY=$1
ABI=$2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARGET_DIR="$ROOT/android/app/src/main/jniLibs/$ABI"
TARGET="$TARGET_DIR/libaria2c.so"

case "$ABI" in
  arm64-v8a|armeabi-v7a|x86_64) ;;
  *)
    echo "Unsupported ABI: $ABI" >&2
    exit 64
    ;;
esac

if [[ ! -f "$BINARY" ]]; then
  echo "Binary not found: $BINARY" >&2
  exit 66
fi

if command -v file >/dev/null 2>&1; then
  echo "Binary type: $(file -b "$BINARY")"
fi

mkdir -p "$TARGET_DIR"
cp "$BINARY" "$TARGET"
chmod 755 "$TARGET"

# Strip with the NDK toolchain when available to keep the APK small.
NDK_STRIP=$(find "${ANDROID_NDK_HOME:-$ANDROID_NDK_ROOT}" \
  -path '*/toolchains/llvm/prebuilt/*/bin/llvm-strip' 2>/dev/null | head -n 1 || true)
if [[ -n "${NDK_STRIP:-}" && -x "$NDK_STRIP" ]]; then
  "$NDK_STRIP" --strip-all "$TARGET" || true
fi

echo "Installed: $TARGET"
echo "Next: flutter build apk --split-per-abi   (or flutter run on a device)"
