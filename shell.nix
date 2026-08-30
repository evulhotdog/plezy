# plezy: disposable build env — nix-shell this to get Flutter + JDK 21 + Android SDK
# without polluting the host. Mirrors silo-android's shell.nix, but AGP needs
# NDK/CMake/platform versions the nix SDK does not ship, so version
# subdirectories are symlinked individually and the parent dirs stay writable:
# AGP auto-installs the missing pieces (NDK 29.0.14206865, CMake 4.1.2,
# platforms;android-36) into the scratch root on first build.
{ pkgs ? import <nixpkgs> { config = { allowUnfree = true; android_sdk.accept_license = true; }; } }:
let
  androidSdk = pkgs.androidenv.androidPkgs.androidsdk;
  sdkSrc = "${androidSdk}/libexec/android-sdk";
  sdkRoot = "/Users/briandavis/.cache/plezy-android-sdk";
in
pkgs.mkShell {
  packages = [ pkgs.jdk21 pkgs.flutter ];
  ANDROID_SDK_ROOT = sdkRoot;
  ANDROID_HOME = sdkRoot;
  JAVA_HOME = pkgs.jdk21.home;
  shellHook = ''
    # AGP wants SDK components the nix store SDK lacks; the writable scratch
    # root lets AGP auto-install them.
    # Bootstrap-if-missing: concurrent nix-shells (checks + gradle build) must
    # not yank the scratch SDK out from under a running build.
    if [ ! -e "${sdkRoot}/licenses" ]; then
      rm -rf "${sdkRoot}"
      mkdir -p "${sdkRoot}/build-tools" "${sdkRoot}/licenses" "${sdkRoot}/ndk" "${sdkRoot}/cmake"
      for d in "${sdkSrc}"/*; do
        case "$(basename "$d")" in build-tools|licenses|ndk|ndk-bundle|cmake) continue;; esac
        ln -sfn "$d" "${sdkRoot}/$(basename "$d")"
      done
      for d in "${sdkSrc}/build-tools"/*; do ln -sfn "$d" "${sdkRoot}/build-tools/$(basename "$d")"; done
      for d in "${sdkSrc}/ndk"/*; do ln -sfn "$d" "${sdkRoot}/ndk/$(basename "$d")"; done
      for d in "${sdkSrc}/cmake"/*; do ln -sfn "$d" "${sdkRoot}/cmake/$(basename "$d")"; done
      for d in "${sdkSrc}/licenses"/*; do cp "$d" "${sdkRoot}/licenses/$(basename "$d")"; done
    fi
    # Standalone `dart` (used by scripts/ci_checks.sh and `dart run slang`)
    # resolves `sdk: flutter` constraints only when FLUTTER_ROOT is set.
    export FLUTTER_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
    # Native build hooks (objective_c via `dart run`) invoke
    # `xcrun --sdk macosx ...`, which nix's fake xcbuild xcrun cannot serve —
    # its error text was literally being passed as the sysroot. Use the real
    # CLT xcrun + SDK instead.
    mkdir -p ''${HOME}/.cache/plezy-shims
    ln -sfn /usr/bin/xcrun ''${HOME}/.cache/plezy-shims/xcrun
    export PATH="''${HOME}/.cache/plezy-shims:$PATH"
    export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
  '';
}
