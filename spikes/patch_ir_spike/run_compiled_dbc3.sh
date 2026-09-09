#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
spike_dir="$repo_dir/spikes/patch_ir_spike"
sdk_dir=${DART_SDK_SOURCE:-"$repo_dir/work/upstream/dart-sdk"}
out_dir="$sdk_dir/xcodebuild/ReleaseARM64"
dart_bin=${DART_BIN:-dart}
test "$(git -C "$sdk_dir" rev-parse HEAD)" = c70f78e7d682c158c15ca0c26c729b3ccb932284
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/compiled-dbc3.XXXXXX")
test_dir=$(CDPATH= cd -- "$test_dir" && pwd -P)
trap 'rm -r -- "$test_dir"' EXIT
cc -std=c11 -Wall -Wextra -Werror -fPIC -dynamiclib \
  "$repo_dir/native/patch_store_io.c" -o "$test_dir/libpatch_store_io.dylib"

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
  release_dir="$artifact_dir/release"
  patch_dir="$artifact_dir/patch"
  HOTFIX_TEST_PUBLIC_KEY="$public_key" HOTFIX_NATIVE_STORE=true "$dart_bin" \
    --packages="$sdk_dir/.dart_tool/package_config.json" \
    "$spike_dir/tool/compile_dbc3_patch.dart" release "$sdk_dir" \
    "$fixture_dir/baseline.dart" "$release_dir" "$entry"
  "$out_dir/gen_snapshot_product" --snapshot-kind=app-aot-elf \
    --elf="$release_dir/baseline.snapshot" "$release_dir/baseline.aot.dill"
  frozen_hash=$(shasum -a 256 "$release_dir/baseline.snapshot" "$release_dir/baseline.input.dill" "$release_dir/release.json")
  "$dart_bin" --packages="$sdk_dir/.dart_tool/package_config.json" \
    "$spike_dir/tool/compile_dbc3_patch.dart" patch "$sdk_dir" \
    "$release_dir" "$fixture_dir/updated.dart" "$patch_dir"
  test "$frozen_hash" = "$(shasum -a 256 "$release_dir/baseline.snapshot" "$release_dir/baseline.input.dill" "$release_dir/release.json")"
  baseline_id=$(cat "$release_dir/baseline.id")
  "$dart_bin" "$spike_dir/tool/signature_check.dart" sign "$test_dir/signing" \
    "$patch_dir/patch.bytecode" "$patch_dir/manifest.json" "$baseline_id"
  HOTFIX_TEST_NATIVE_LIBRARY="$test_dir/libpatch_store_io.dylib" \
    "$out_dir/dartaotruntime_product" "$release_dir/baseline.snapshot" \
    "$patch_dir/patch.bytecode" "$patch_dir/manifest.json" "$artifact_dir/store"
  if [ "$fixture" = greeting ]; then
    sed 's/"signature":"/"signature":"A/' "$patch_dir/manifest.json" > "$patch_dir/forged.json"
    HOTFIX_TEST_NATIVE_LIBRARY="$test_dir/libpatch_store_io.dylib" \
      "$out_dir/dartaotruntime_product" "$release_dir/baseline.snapshot" \
      "$patch_dir/patch.bytecode" "$patch_dir/forged.json" "$artifact_dir/rejected-store" expect-baseline
  fi
done
"$dart_bin" "$spike_dir/tool/native_store_check.dart" "$test_dir/libpatch_store_io.dylib"
echo 'PASS: frozen release -> signed patch -> native transactional store -> existing AOT baseline'
"$dart_bin" --packages="$sdk_dir/.dart_tool/package_config.json" \
  "$spike_dir/tool/frozen_release_check.dart" "$sdk_dir" "$test_dir/libpatch_store_io.dylib"
"$dart_bin" --packages="$sdk_dir/.dart_tool/package_config.json" \
  "$spike_dir/tool/relative_import_check.dart" "$sdk_dir"

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
