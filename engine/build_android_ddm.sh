#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
abi=${1:-arm64}
case "$abi" in arm) generator=armv7 ;; arm64) generator=arm64 ;; *) echo 'Use arm or arm64' >&2; exit 2 ;; esac
engine=${2:-"$root/work/upstream/flutter-engine-ddm"}
test "$(git -C "$engine" rev-parse HEAD)" = 00b0c91f06209d9e4a41f71b7a512d6eb3b9c694
if [ "$abi" = arm ]; then
  git -C "$engine/engine/src/flutter/third_party/dart" apply --reverse --check \
    "$root/engine/patches/arm32_interpreter_pool.patch" || {
      echo 'Apply engine/patches/arm32_interpreter_pool.patch in the isolated Dart checkout first' >&2
      exit 1
    }
fi
export PATH="$root/work/upstream/depot_tools:$PATH"
export VPYTHON_BYPASS='manually managed python not supported by chrome operations'
cd "$engine/engine/src"
output="hotfix_android_release_$abi"
python3 flutter/tools/gn --android --android-cpu="$abi" --runtime-mode=release \
  --no-lto --no-prebuilt-dart-sdk --no-full-dart-sdk --no-build-engine-artifacts \
  --dart-dynamic-modules --allow-deprecated-api-calls --target-dir="$output" \
  --gn-args=enable_unittests=false
test "$(flutter/third_party/gn/gn args "out/$output" --list=dart_dynamic_modules --short)" = 'dart_dynamic_modules = true'
exec ../../third_party/ninja/ninja -j2 -C "out/$output" \
  flutter/shell/platform/android:flutter_shell_native \
  "flutter/lib/snapshot:create_macos_gen_snapshot_arm64_$generator"
