#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
engine_dir=${FLUTTER_ENGINE_SOURCE:-"$repo_dir/work/upstream/flutter-engine-ddm/engine/src/flutter"}
header_dir="$engine_dir/shell/platform/embedder"
test "$(git -C "$engine_dir" rev-parse HEAD)" = 00b0c91f06209d9e4a41f71b7a512d6eb3b9c694
header_hash=$(shasum -a 256 "$header_dir/embedder.h")
case "$header_hash" in
  4d004e246a5c5aea606248fa346920ffae71fc5c60bbff14d932b661c77ba729\ *) ;;
  *) echo 'FAIL: pinned embedder header changed' >&2; exit 1 ;;
esac
output_dir=$(mktemp -d "$repo_dir/work/headless-aot-smoke.XXXXXX")
binary="$output_dir/headless_aot_smoke"
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror -pedantic -pthread \
  -I "$header_dir" "$repo_dir/engine/headless_aot_smoke.cc" -o "$binary"
if nm -u "$binary" | rg -q FlutterEngine; then
  echo 'FAIL: runner unexpectedly links Flutter Engine symbols' >&2
  exit 1
fi
if failure=$("$binary" "$output_dir/missing-engine" unused unused unused 1 2>&1); then
  echo 'FAIL: unavailable Engine was accepted' >&2
  exit 1
fi
printf '%s\n' "$failure" | rg -q 'FAIL: dlopen:'
if failure=$("$binary" /usr/lib/libSystem.B.dylib unused unused unused 1 2>&1); then
  echo 'FAIL: unrelated system library was accepted as Flutter Engine' >&2
  exit 1
fi
printf '%s\n' "$failure" | rg -q 'FAIL: missing FlutterEngineGetProcAddresses'
printf 'PASS: pinned header compilation and missing-Engine/symbol rejection gates\nRunner: %s\n' "$binary"
echo 'UNVERIFIED: real Flutter Engine AOT loading, software frames and Dart result'
