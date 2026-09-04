#!/bin/sh
set -eu

cd "$(dirname "$0")"
dart_bin=${DART_BIN:-dart}
dart_revision=c70f78e7d682c158c15ca0c26c729b3ccb932284
dart_source=../../work/upstream/dart-sdk
dart_sdk=$(cd "$(dirname "$dart_bin")/../bin/cache/dart-sdk" 2>/dev/null && pwd || true)
if [ -z "$dart_sdk" ]; then
  dart_sdk=$(cd "$(dirname "$dart_bin")/../cache/dart-sdk" && pwd)
fi

if [ ! -d "$dart_source/.git" ]; then
  mkdir -p "$dart_source"
  git -C "$dart_source" init
  git -C "$dart_source" remote add origin https://github.com/dart-lang/sdk.git
  git -C "$dart_source" sparse-checkout init --cone
  git -C "$dart_source" sparse-checkout set pkg/kernel pkg/_fe_analyzer_shared pkg/dynamic_modules sdk/lib
  git -C "$dart_source" fetch --depth=1 origin "$dart_revision"
  git -C "$dart_source" checkout --detach FETCH_HEAD
fi

test "$(git -C "$dart_source" rev-parse HEAD)" = "$dart_revision"
"$dart_bin" pub get
"$dart_bin" format runtime.dart patch_store.dart tool fixtures
"$dart_sdk/bin/dartaotruntime" "$dart_sdk/bin/snapshots/dart2bytecode.dart.snapshot" \
  --platform "$dart_sdk/lib/_internal/vm_platform.dill" \
  --target vm \
  --output .dart_tool/dynamic_module.bytecode \
  fixtures/dynamic_module.dart
"$dart_bin" compile exe tool/upstream_module_runner.dart -o .dart_tool/upstream_module_runner
set +e
module_output=$(.dart_tool/upstream_module_runner .dart_tool/dynamic_module.bytecode 2>&1)
module_status=$?
set -e
printf '%s\n' "$module_output"
if [ "$module_status" -ne 0 ] && [ "$module_status" -ne 78 ]; then
  exit "$module_status"
fi
"$dart_bin" tool/build.dart
"$dart_bin" compile exe .dart_tool/generated_runner.dart -o .dart_tool/generated_runner
.dart_tool/generated_runner
"$dart_bin" compile exe .dart_tool/patch_point.dill -o .dart_tool/patch_point_runner
.dart_tool/patch_point_runner
"$dart_bin" compile exe tool/store_check.dart -o .dart_tool/store_check
.dart_tool/store_check
