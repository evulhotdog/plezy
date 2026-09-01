#!/usr/bin/env bash
# Fast iterate loop: build the current tree and install it on the Shield.
#
#   scripts/build_install.sh [--device HOST:PORT] [--build-number N] [--no-install]
#
# No verification gate — run scripts/ci_checks.sh separately when you want
# the full check. This script does only what a safe install requires:
# versionCode bump (installed + 1), arm64 release build, signature check
# against the installed build (a mismatch would force adb uninstall and
# wipe data/logins), adb install -r, launch.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$HERE/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

DEVICE="10.0.10.177:5555"
PACKAGE="com.edde746.plezy"
BUILD_NUMBER=""
NO_INSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --no-install) NO_INSTALL=1; shift ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# Toolchain comes from shell.nix; re-exec once inside it if we are on the host.
if ! command -v flutter >/dev/null 2>&1 || ! command -v dart >/dev/null 2>&1; then
  if [ -f "$ROOT/shell.nix" ] && command -v nix-shell >/dev/null 2>&1; then
    exec nix-shell --run "$(printf '%q ' "$SCRIPT_PATH" "$@")"
  fi
  echo "error: flutter/dart not on PATH and shell.nix is unavailable on this branch" >&2
  exit 1
fi
command -v adb >/dev/null 2>&1 || { echo "error: adb not on PATH" >&2; exit 1; }

APK="build/app/outputs/flutter-apk/app-release.apk"

# Device up + versionCode. Dev builds must outrank whatever is installed or
adb connect "$DEVICE" >/dev/null 2>&1
adb -s "$DEVICE" shell echo ok >/dev/null 2>&1 || { echo "error: device $DEVICE unreachable" >&2; exit 1; }

installed_vc="$(adb -s "$DEVICE" shell dumpsys package "$PACKAGE" 2>/dev/null | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1 | tr -d '[:space:]')"
if [ -z "$BUILD_NUMBER" ]; then
  if [ -n "$installed_vc" ]; then
    BUILD_NUMBER=$((installed_vc + 1))
  else
    echo "error: app not installed on device; pass --build-number for a fresh install" >&2
    exit 1
  fi
fi
echo "==> device $DEVICE (installed versionCode=${installed_vc:-none}, building $BUILD_NUMBER)"

echo "==> flutter build apk --release --build-number=$BUILD_NUMBER"
flutter build apk --release --target-platform android-arm64 --build-number="$BUILD_NUMBER" || exit 1
[ -f "$APK" ] || { echo "error: expected APK missing: $APK" >&2; exit 1; }

if [ "$NO_INSTALL" -eq 1 ]; then
  echo "==> built $APK (versionCode $BUILD_NUMBER), install skipped (--no-install)"
  exit 0
fi

# Signature check: a mismatch would force adb uninstall -> data wipe; stop.
if [ -n "$installed_vc" ]; then
  apk_path="$(adb -s "$DEVICE" shell pm path "$PACKAGE" | sed 's/^package://;s/\r$//' | head -1)"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  adb -s "$DEVICE" pull "$apk_path" "$tmpdir/installed-base.apk" >/dev/null

  apksigner=""
  for root in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$HOME/.cache/plezy-android-sdk"; do
    [ -n "$root" ] || continue
    apksigner="$(ls "$root"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)"
    [ -n "$apksigner" ] && break
  done
  [ -n "$apksigner" ] || { echo "error: apksigner not found; cannot verify signatures" >&2; exit 1; }

  sig_installed="$("$apksigner" verify --print-certs "$tmpdir/installed-base.apk" 2>/dev/null | sed -n 's/.*certificate SHA-256 digest: //p' | head -1)"
  sig_new="$("$apksigner" verify --print-certs "$APK" 2>/dev/null | sed -n 's/.*certificate SHA-256 digest: //p' | head -1)"
  if [ -z "$sig_installed" ] || [ -z "$sig_new" ] || [ "$sig_installed" != "$sig_new" ]; then
    echo "error: signature mismatch (installed=$sig_installed new=$sig_new)" >&2
    echo "       installing would require adb uninstall and wipe app data/logins; aborting" >&2
    exit 1
  fi
  echo "==> signatures match, installing"
fi

adb -s "$DEVICE" install -r "$APK" || exit 1

vc_now="$(adb -s "$DEVICE" shell dumpsys package "$PACKAGE" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1 | tr -d '[:space:]')"
[ "$vc_now" = "$BUILD_NUMBER" ] || { echo "error: device reports versionCode=$vc_now, expected $BUILD_NUMBER" >&2; exit 1; }

adb -s "$DEVICE" logcat -c 2>/dev/null
adb -s "$DEVICE" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 5
pid="$(adb -s "$DEVICE" shell pidof "$PACKAGE" | tr -d '[:space:]')"
[ -n "$pid" ] || { echo "error: app did not start" >&2; exit 1; }

echo "==> done: running on $DEVICE (pid $pid, versionCode $vc_now)"