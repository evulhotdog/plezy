#!/usr/bin/env bash
# Fast iteration loop: run the current tree on the Shield in --debug mode
# and keep it attached for HOT RELOAD. Unlike build_install.sh (release APK +
# install), this is the sub-second feel-tuning loop: change a constant, save,
# hit 'r' in the flutter terminal, replay the gesture on the TV. No rebuild,
# no reinstall — the app is installed once, then 'r' pushes Dart changes.
#
# --debug (not --profile): hot reload/restart are only wired in debug builds —
# flutter_tools' shouldUseHotMode requires buildInfo.isDebug. Profile builds
# run AOT and the interactive console omits r/R entirely.
#   r    hot reload (reapplies Dart changes incl. static consts; ~1s)
#   R    hot restart (rebuilds widget tree from scratch)
#   q    quit and detach (leaves the app installed)
#   h    help for all keys
#
# Flags:
#   --device   adb target (default 10.0.10.177:5555)
#   -c, --clear-logcat   clear device logcat before launching, so the next
#                        burst of output is only this run
#   --                  everything after is passed through to `flutter run`
#
# VersionCode: `flutter run` derives the Android versionCode from the
# pubspec's `version: x.y.z+<build>` and has no --build-number flag, so the
# pubspec build number must outrank whatever is installed or the install is
# refused as a downgrade. This script checks that and errors with the fix if
# not. Bump the pubspec build number once to start (e.g. +N where N >
# installed), then hot reload is free for the whole session.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$HERE/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

DEVICE="10.0.10.177:5555"
PACKAGE="com.edde746.plezy"
CLEAR_LOG=0
FLUTTER_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    -c|--clear-logcat) CLEAR_LOG=1; shift ;;
    --) shift; FLUTTER_ARGS+=("$@"); break ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) FLUTTER_ARGS+=("$1"); shift ;;
  esac
done

# Toolchain comes from shell.nix; re-exec once inside it if we are on the host.
if ! command -v flutter >/dev/null 2>&1 || ! command -v dart >/dev/null 2>&1; then
  if command -v nix-shell >/dev/null 2>&1; then
    # The nix env lives on the build/nix-shell branch; work from any checkout.
    NIX_ENV="$ROOT/shell.nix"
    if [ ! -f "$NIX_ENV" ] && command -v git >/dev/null 2>&1; then
      NIX_ENV="$(mktemp)"
      git show build/nix-shell:shell.nix > "$NIX_ENV" 2>/dev/null \
        || git show origin/build/nix-shell:shell.nix > "$NIX_ENV" 2>/dev/null
    fi
    if [ -f "$NIX_ENV" ]; then
      exec nix-shell "$NIX_ENV" --run "$(printf '%q ' "$SCRIPT_PATH" -- "$@")"
    fi
  fi
  echo "error: flutter/dart not on PATH and no nix env available" >&2
  echo "       (shell.nix is committed on the build/nix-shell branch; fetch it or" >&2
  echo "        run this from a checkout that has it)" >&2
  exit 1
fi
command -v adb >/dev/null 2>&1 || { echo "error: adb not on PATH" >&2; exit 1; }

adb connect "$DEVICE" >/dev/null 2>&1
adb -s "$DEVICE" shell echo ok >/dev/null 2>&1 || { echo "error: device $DEVICE unreachable" >&2; exit 1; }

installed_vc="$(adb -s "$DEVICE" shell dumpsys package "$PACKAGE" 2>/dev/null | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1 | tr -d '[:space:]')"
if [ -z "$installed_vc" ]; then
  echo "error: app not installed on device; build+install once via build_install.sh first" >&2
  exit 1
fi

# flutter run builds versionCode from the pubspec build number (the +N in
# `version:`). It must be >= installed or adb refuses the downgrade (equal is
# fine: same signature + same versionCode is a clean -r reinstall).
pubspec_vc="$(sed -n 's/^version:.*+\([0-9][0-9]*\).*/\1/p' "$ROOT/pubspec.yaml" | head -1)"
if [ -z "$pubspec_vc" ] || [ "$pubspec_vc" -lt "$installed_vc" ]; then
  echo "error: pubspec build number (+$pubspec_vc) is below installed versionCode $installed_vc" >&2
  echo "       'flutter run' has no --build-number flag; bump pubspec.yaml's version: to" >&2
  echo "       x.y.z+$((installed_vc + 1)) or higher once, then rerun. Hot reload then needs no reinstall." >&2
  exit 1
fi
# (what every local --debug build uses). A mismatch would force adb uninstall
# and wipe app data/logins, so abort before trying.
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
debug_keystore="${DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"
sig_debug="$(keytool -exportcert -alias androiddebugkey -keystore "$debug_keystore" -storepass android 2>/dev/null | openssl dgst -sha256 | sed 's/.*= *//')"
if [ -z "$sig_installed" ] || [ -z "$sig_debug" ] || [ "$sig_installed" != "$sig_debug" ]; then
  echo "error: installed build (${sig_installed:-?}) does not match the debug keystore (${sig_debug:-?})" >&2
  echo "       installing would force adb uninstall and wipe app data/logins; aborting." >&2
  echo "       release builds (scripts/build_install.sh) use a different key — dev runs won't overwrite them." >&2
  exit 1
fi

if [ "$CLEAR_LOG" -eq 1 ]; then
  adb -s "$DEVICE" logcat -c 2>/dev/null
  echo "==> logcat cleared"
fi

echo "==> flutter run --debug on $DEVICE (installed v$installed_vc, pubspec +$pubspec_vc)"
echo "    hot keys in the session: r=hot reload  R=hot restart  q=quit"
exec flutter run --debug -d "$DEVICE" "${FLUTTER_ARGS[@]}"
