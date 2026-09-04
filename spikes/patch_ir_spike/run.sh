#!/bin/sh
set -eu

cd "$(dirname "$0")"
dart_bin=${DART_BIN:-dart}
dart_revision=c70f78e7d682c158c15ca0c26c729b3ccb932284
dart_source=../../work/upstream/dart-sdk

if [ ! -d "$dart_source/.git" ]; then
  mkdir -p "$dart_source"
  git -C "$dart_source" init
  git -C "$dart_source" remote add origin https://github.com/dart-lang/sdk.git
  git -C "$dart_source" sparse-checkout init --cone
  git -C "$dart_source" sparse-checkout set pkg/kernel pkg/_fe_analyzer_shared sdk/lib
  git -C "$dart_source" fetch --depth=1 origin "$dart_revision"
  git -C "$dart_source" checkout --detach FETCH_HEAD
fi

test "$(git -C "$dart_source" rev-parse HEAD)" = "$dart_revision"
"$dart_bin" pub get
"$dart_bin" format runtime.dart patch_store.dart tool fixtures
"$dart_bin" tool/build.dart
"$dart_bin" compile exe .dart_tool/generated_runner.dart -o .dart_tool/generated_runner
.dart_tool/generated_runner
"$dart_bin" compile exe .dart_tool/patch_point.dill -o .dart_tool/patch_point_runner
.dart_tool/patch_point_runner
"$dart_bin" compile exe tool/store_check.dart -o .dart_tool/store_check
.dart_tool/store_check
