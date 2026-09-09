#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
sdk_dir=${DART_SDK_SOURCE:-"$repo_dir/work/upstream/dart-sdk"}
out_dir="$sdk_dir/xcodebuild/ReleaseARM64"
fixture_dir="$repo_dir/spikes/patch_ir_spike"
dart_bin=${DART_BIN:-dart}
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

"$dart_bin" pub get --directory "$fixture_dir"
"$dart_bin" "$fixture_dir/tool/signature_check.dart" keygen "$tmp_dir/signing"
public_key=$(cat "$tmp_dir/signing/public-key.txt")

compile_kernel() {
  aot_flag=$1
  output=$2
  "$out_dir/dartaotruntime_product" --disable-dart-dev \
    "$out_dir/gen/gen_kernel_aot.dart.snapshot" \
    --target vm \
    --packages "$fixture_dir/.dart_tool/package_config.json" \
    -Ddart.vm.profile=false -Ddart.vm.product=true \
    "-DHOTFIX_TEST_PUBLIC_KEY=$public_key" \
    "$aot_flag" --no-embed-sources \
    --platform "$out_dir/vm_platform.dill" \
    --output "$output" \
    --filesystem-root "$fixture_dir" \
    --filesystem-scheme dev-hotfix \
    --dynamic-interface dev-hotfix:/dynamic_aot/dynamic_interface.yaml \
    dev-hotfix:/dynamic_aot/main.dart
}

compile_kernel --aot "$tmp_dir/main_aot.dill"
compile_kernel --no-aot "$tmp_dir/main_no_aot.dill"

"$out_dir/gen_snapshot_product" \
  --snapshot-kind=app-aot-elf \
  --elf="$tmp_dir/main.snapshot" \
  "$tmp_dir/main_aot.dill"

for module in patch failing_patch; do
"$out_dir/dartaotruntime_product" --disable-dart-dev \
  "$out_dir/gen/dart2bytecode.dart.snapshot" \
  --platform "$out_dir/vm_platform.dill" \
  --target vm \
  --packages "$fixture_dir/.dart_tool/package_config.json" \
  -Ddart.vm.profile=false -Ddart.vm.product=true \
  --import-dill "$tmp_dir/main_no_aot.dill" \
  --validate dev-hotfix:/dynamic_aot/dynamic_interface.yaml \
  --filesystem-root "$fixture_dir" \
  --filesystem-scheme dev-hotfix \
  --output "$tmp_dir/modules/$module.dart.bytecode" \
  "dev-hotfix:/dynamic_aot/modules/$module.dart"
done

"$dart_bin" "$fixture_dir/tool/signature_check.dart" sign \
  "$tmp_dir/signing" "$tmp_dir/modules/patch.dart.bytecode" "$tmp_dir/manifest.json"
"$dart_bin" "$fixture_dir/tool/signature_check.dart" sign \
  "$tmp_dir/signing" "$tmp_dir/modules/failing_patch.dart.bytecode" \
  "$tmp_dir/failing-manifest.json" dbc3-host-baseline-v1 p2
"$dart_bin" "$fixture_dir/tool/signature_check.dart" sign \
  "$tmp_dir/signing" "$tmp_dir/modules/patch.dart.bytecode" \
  "$tmp_dir/same-uri-manifest.json" dbc3-host-baseline-v1 p2
sed 's/dbc3-host-baseline-v1/wrong-baseline/' \
  "$tmp_dir/manifest.json" > "$tmp_dir/bad-manifest.json"
cp "$tmp_dir/modules/patch.dart.bytecode" "$tmp_dir/modules/tampered.bytecode"
printf 'x' >> "$tmp_dir/modules/tampered.bytecode"

set +e
runtime_output=$(cd "$tmp_dir" && \
  "$out_dir/dartaotruntime_product" --verbose-gc main.snapshot 2>&1)
runtime_status=$?
set -e
if [ "$runtime_status" -ne 0 ]; then
  printf '%s\n' "$runtime_output" >&2
  exit "$runtime_status"
fi
printf '%s\n' "$runtime_output" | grep '^PASS:'
gc_count=$(printf '%s\n' "$runtime_output" | grep -c 'Scavenge')
test "$gc_count" -gt 0
echo "PASS: observed $gc_count scavenges while interpreted frames were live"
for scenario in fallback double-failure same-uri persist-failure; do
  (cd "$tmp_dir" && "$out_dir/dartaotruntime_product" main.snapshot \
    seed "lkg-$scenario")
  (cd "$tmp_dir" && "$out_dir/dartaotruntime_product" main.snapshot \
    "$scenario" "lkg-$scenario")
done
