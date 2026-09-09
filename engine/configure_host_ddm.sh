#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
engine_dir=${1:-"$repo_dir/work/upstream/flutter-engine-ddm"}
test "$(git -C "$engine_dir" rev-parse HEAD)" = 00b0c91f06209d9e4a41f71b7a512d6eb3b9c694
git -C "$engine_dir" apply --reverse --check "$repo_dir/engine/patches/host_clang_plist.patch" || {
  echo 'FAIL: apply engine/patches/host_clang_plist.patch to the isolated Engine checkout first' >&2
  exit 1
}
export PATH="$repo_dir/work/upstream/depot_tools:$PATH"
export VPYTHON_BYPASS='manually managed python not supported by chrome operations'
cd "$engine_dir/engine/src"

# In this pinned upstream script, --no-enable-unittests also sets
# dart_dynamic_modules=false. Use the raw test GN argument instead, and inspect
# the effective configuration before any native compilation is allowed.
python3 flutter/tools/gn --runtime-mode=release --mac-cpu=arm64 --no-lto \
  --no-prebuilt-dart-sdk --no-full-dart-sdk --no-build-engine-artifacts \
  --dart-dynamic-modules --allow-deprecated-api-calls \
  --target-dir=hotfix_host_release_arm64 --gn-args=enable_unittests=false

check_arg() {
  value=$(flutter/third_party/gn/gn args out/hotfix_host_release_arm64 \
    "--list=$1" --short)
  # This pinned GN writes nonfatal warnings before its single requested value.
  # Its exit status remains checked by set -e; only the final value line counts.
  value=$(printf '%s\n' "$value" | tail -n 1)
  test "$value" = "$1 = $2" || {
    echo "FAIL: unexpected effective GN argument: $value" >&2
    exit 1
  }
}
check_arg dart_dynamic_modules true
check_arg flutter_runtime_mode '"release"'
check_arg target_cpu '"arm64"'
defines=$(flutter/third_party/gn/gn desc out/hotfix_host_release_arm64 \
  //flutter/third_party/dart/runtime:libdart_aotruntime defines)
for definition in DART_DYNAMIC_MODULES PRODUCT DART_PRECOMPILED_RUNTIME; do
  printf '%s\n' "$defines" | grep -Fxq "$definition" || {
    echo "FAIL: AOT runtime is missing $definition" >&2
    exit 1
  }
done
echo 'PASS: effective host Engine configuration is arm64 release with DDM enabled'
