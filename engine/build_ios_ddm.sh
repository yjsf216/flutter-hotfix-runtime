#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
export PATH="$repo_dir/work/upstream/depot_tools:$PATH"
export VPYTHON_BYPASS='manually managed python not supported by chrome operations'
cd "$repo_dir/work/upstream/flutter-engine-ddm/engine/src"
xcrun --sdk iphoneos metal --version
for expected in 'target_os = "ios"' 'target_cpu = "arm64"' \
  'dart_dynamic_modules = true' 'flutter_runtime_mode = "release"' \
  'use_ios_simulator = false'; do
  name=${expected%% *}
  actual=$(flutter/third_party/gn/gn args out/hotfix_ios_release_arm64 \
    "--list=$name" --short | tail -n 1)
  test "$actual" = "$expected" || { echo "FAIL: $actual" >&2; exit 1; }
done
exec ../../third_party/ninja/ninja -j2 -C out/hotfix_ios_release_arm64 \
  flutter/shell/platform/darwin/ios:flutter_framework \
  flutter/lib/snapshot:create_macos_gen_snapshot_arm64_arm64
