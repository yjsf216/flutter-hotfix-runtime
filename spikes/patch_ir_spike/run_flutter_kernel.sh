#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
spike_dir="$repo_dir/spikes/patch_ir_spike"
sdk_dir=${DART_SDK_SOURCE:-"$repo_dir/work/upstream/dart-sdk"}
flutter_dir=${FLUTTER_SDK:-"/path/to/flutter"}
dart_bin=${DART_BIN:-"$flutter_dir/bin/cache/dart-sdk/bin/dart"}
if [ "$#" -gt 0 ]; then
  output_dir=$1
else
  output_dir=$(mktemp -d "$repo_dir/work/flutter-kernel-check.XXXXXX")
fi
test "$(git -C "$sdk_dir" rev-parse HEAD)" = c70f78e7d682c158c15ca0c26c729b3ccb932284

set -- "$sdk_dir" "$flutter_dir" "$output_dir"
if [ "${GEN_SNAPSHOT+x}" = x ]; then
  test -n "$GEN_SNAPSHOT" || { echo 'FAIL: GEN_SNAPSHOT is empty' >&2; exit 1; }
  set -- "$@" "$GEN_SNAPSHOT"
fi
"$dart_bin" --packages="$sdk_dir/.dart_tool/package_config.json" \
  "$spike_dir/tool/flutter_kernel_check.dart" "$@"
