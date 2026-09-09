#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
spike_dir="$repo_dir/spikes/patch_ir_spike"
sdk_dir=${DART_SDK_SOURCE:-"$repo_dir/work/upstream/dart-sdk"}
out_dir="$sdk_dir/xcodebuild/ReleaseARM64"
dart_bin=${DART_BIN:-dart}
test "$(git -C "$sdk_dir" rev-parse HEAD)" = c70f78e7d682c158c15ca0c26c729b3ccb932284
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/compiled-dbc3.XXXXXX")
trap 'rm -r -- "$test_dir"' EXIT

"$dart_bin" pub get --directory "$spike_dir"
"$dart_bin" "$spike_dir/tool/signature_check.dart" keygen "$test_dir/signing"
public_key=$(cat "$test_dir/signing/public-key.txt")

for fixture in greeting language; do
  if [ "$fixture" = greeting ]; then
    fixture_dir="$spike_dir/fixtures"
    entry="$fixture_dir/compiled_entry.dart"
  else
    fixture_dir="$spike_dir/fixtures/compiled_cases"
    entry="$fixture_dir/main.dart"
  fi
  artifact_dir="$test_dir/$fixture"
  HOTFIX_TEST_PUBLIC_KEY="$public_key" "$dart_bin" \
    --packages="$sdk_dir/.dart_tool/package_config.json" \
    "$spike_dir/tool/compile_dbc3_patch.dart" "$sdk_dir" \
    "$fixture_dir/baseline.dart" "$fixture_dir/updated.dart" "$artifact_dir" "$entry"
  "$out_dir/gen_snapshot_product" --snapshot-kind=app-aot-elf \
    --elf="$artifact_dir/baseline.snapshot" "$artifact_dir/baseline.aot.dill"
  baseline_id=$(cat "$artifact_dir/baseline.id")
  "$dart_bin" "$spike_dir/tool/signature_check.dart" sign "$test_dir/signing" \
    "$artifact_dir/patch.bytecode" "$artifact_dir/manifest.json" "$baseline_id"
  "$out_dir/dartaotruntime_product" "$artifact_dir/baseline.snapshot" \
    "$artifact_dir/patch.bytecode" "$artifact_dir/manifest.json" "$artifact_dir/store"
  if [ "$fixture" = greeting ]; then
    sed 's/"signature":"/"signature":"A/' "$artifact_dir/manifest.json" > "$artifact_dir/forged.json"
    "$out_dir/dartaotruntime_product" "$artifact_dir/baseline.snapshot" \
      "$artifact_dir/patch.bytecode" "$artifact_dir/forged.json" "$artifact_dir/rejected-store" expect-baseline
  fi
done

for incompatible in field_changed signature_changed; do
  if rejection=$(HOTFIX_TEST_PUBLIC_KEY="$public_key" "$dart_bin" \
    --packages="$sdk_dir/.dart_tool/package_config.json" \
    "$spike_dir/tool/compile_dbc3_patch.dart" "$sdk_dir" \
    "$spike_dir/fixtures/baseline.dart" "$spike_dir/fixtures/$incompatible.dart" \
    "$test_dir/$incompatible" 2>&1); then
    echo "incompatible change accepted: $incompatible" >&2
    exit 1
  fi
  printf '%s\n' "$rejection" | grep -q 'incompatible Kernel library'
  test ! -f "$test_dir/$incompatible/patch.bytecode"
done
echo 'PASS: incompatible source changes rejected before DBC3 emission'
"$dart_bin" --packages="$sdk_dir/.dart_tool/package_config.json" \
  "$spike_dir/tool/kernel_compare_check.dart"
"$dart_bin" "$spike_dir/tool/compiler_gate_check.dart" "$sdk_dir"
