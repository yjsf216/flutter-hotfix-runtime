#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
sdk_dir=${DART_SDK_SOURCE:-"$repo_dir/work/upstream/dart-sdk"}
out_dir="$sdk_dir/xcodebuild/ReleaseARM64"
fixture_dir="$repo_dir/spikes/patch_ir_spike/dynamic_aot"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hotfix-dbc3.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
mkdir "$tmp_dir/modules"

for path in \
  "$out_dir/dartaotruntime_product" \
  "$out_dir/gen_snapshot_product" \
  "$out_dir/gen/gen_kernel_aot.dart.snapshot" \
  "$out_dir/gen/dart2bytecode.dart.snapshot" \
  "$out_dir/vm_platform.dill"
do
  test -f "$path" || { echo "missing custom SDK artifact: $path" >&2; exit 2; }
done

compile_kernel() {
  aot_flag=$1
  output=$2
  "$out_dir/dartaotruntime_product" --disable-dart-dev \
    "$out_dir/gen/gen_kernel_aot.dart.snapshot" \
    --target vm \
    --packages "$sdk_dir/.dart_tool/package_config.json" \
    -Ddart.vm.profile=false -Ddart.vm.product=true \
    "$aot_flag" --no-embed-sources \
    --platform "$out_dir/vm_platform.dill" \
    --output "$output" \
    --filesystem-root "$fixture_dir" \
    --filesystem-scheme dev-hotfix \
    --dynamic-interface dev-hotfix:/dynamic_interface.yaml \
    dev-hotfix:/main.dart
}

compile_kernel --aot "$tmp_dir/main_aot.dill"
compile_kernel --no-aot "$tmp_dir/main_no_aot.dill"

"$out_dir/gen_snapshot_product" \
  --snapshot-kind=app-aot-elf \
  --elf="$tmp_dir/main.snapshot" \
  "$tmp_dir/main_aot.dill"

"$out_dir/dartaotruntime_product" --disable-dart-dev \
  "$out_dir/gen/dart2bytecode.dart.snapshot" \
  --platform "$out_dir/vm_platform.dill" \
  --target vm \
  --packages "$sdk_dir/.dart_tool/package_config.json" \
  -Ddart.vm.profile=false -Ddart.vm.product=true \
  --import-dill "$tmp_dir/main_no_aot.dill" \
  --validate dev-hotfix:/dynamic_interface.yaml \
  --filesystem-root "$fixture_dir" \
  --filesystem-scheme dev-hotfix \
  --output "$tmp_dir/modules/patch.dart.bytecode" \
  dev-hotfix:/modules/patch.dart

(cd "$tmp_dir" && "$out_dir/dartaotruntime_product" main.snapshot)
