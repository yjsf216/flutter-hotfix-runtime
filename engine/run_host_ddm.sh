#!/bin/sh
set -eu

# Host-only Engine proof. This does not launch a device, simulator or window.
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
engine_dir="$repo_dir/work/upstream/flutter-engine-ddm/engine/src"
framework="$engine_dir/out/hotfix_host_release_arm64/FlutterEmbedder.framework/Versions/A"
engine_library="$framework/FlutterEmbedder"
icu="$framework/Resources/icudtl.dat"
for required in "$engine_library" "$icu"; do
  test -f "$required" || {
    echo "FAIL: build the DDM release embedder first; missing $required" >&2
    exit 1
  }
done

spike_dir="$repo_dir/spikes/patch_ir_spike"
dart_bin=${DART_BIN:-/path/to/flutter/bin/cache/dart-sdk/bin/dart}
output_dir=$(mktemp -d "$repo_dir/work/engine-ddm-check.XXXXXX")
echo "Evidence: $output_dir"
runner_check=$(sh "$repo_dir/engine/check_headless_runner.sh")
printf '%s\n' "$runner_check"
runner=$(printf '%s\n' "$runner_check" | sed -n 's/^Runner: //p')
test -x "$runner"

"$dart_bin" "$spike_dir/tool/signature_check.dart" keygen "$output_dir/signing"
public_key=$(cat "$output_dir/signing/public-key.txt")
HOTFIX_TEST_PUBLIC_KEY="$public_key" HOTFIX_NATIVE_STORE=true DART_BIN="$dart_bin" \
  sh "$spike_dir/run_flutter_kernel.sh" "$output_dir/artifacts"
cc -std=c11 -Wall -Wextra -Werror -fPIC -dynamiclib \
  "$repo_dir/native/patch_store_io.c" -o "$output_dir/libpatch_store_io.dylib"
mkdir "$output_dir/assets"
baseline_id=$(cat "$output_dir/artifacts/release/baseline.id")
module="$output_dir/artifacts/patch/patch.bytecode"
manifest="$output_dir/manifest.json"
"$dart_bin" "$spike_dir/tool/signature_check.dart" sign "$output_dir/signing" \
  "$module" "$manifest" "$baseline_id"
sed 's/"signature":"/"signature":"A/' "$manifest" > "$output_dir/forged.json"
wrong_baseline=0000000000000000000000000000000000000000000000000000000000000000
test "$baseline_id" != "$wrong_baseline"
"$dart_bin" "$spike_dir/tool/signature_check.dart" sign "$output_dir/signing" \
  "$module" "$output_dir/mismatched.json" "$wrong_baseline"

run_case() {
  case_name=$1
  shift
  if HOTFIX_TEST_NATIVE_LIBRARY="$output_dir/libpatch_store_io.dylib" \
    "$runner" "$engine_library" "$output_dir/artifacts/baseline.snapshot" \
      "$output_dir/assets" "$icu" 60 "$@" > "$output_dir/$case_name.log" 2>&1; then
    cat "$output_dir/$case_name.log"
  else
    cat "$output_dir/$case_name.log" >&2
    echo "FAIL: actual Engine case $case_name" >&2
    exit 1
  fi
}
run_case baseline
run_case signed "$module" "$manifest" "$output_dir/signed-store"
run_case forged "$module" "$output_dir/forged.json" "$output_dir/forged-store" expect-baseline
run_case mismatched "$module" "$output_dir/mismatched.json" "$output_dir/mismatched-store" expect-baseline
python3 - "$output_dir" "$engine_library" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

output = Path(sys.argv[1])
def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

patch_hash = digest(output / 'artifacts/patch/patch.bytecode')
states = {}
for name in ('signed', 'forged', 'mismatched'):
    state = json.loads((output / f'{name}-store/state.json').read_text())
    accepted = name == 'signed'
    expected = {
        'active': 'p1' if accepted else None,
        'lastKnownGood': 'p1' if accepted else None,
        'pending': None, 'pendingAttempt': None, 'failures': 0,
        'blacklist': [], 'digests': {'p1': patch_hash} if accepted else {},
    }
    if state != expected:
        raise SystemExit(f'FAIL: unexpected durable state for {name}: {state}')
    versions = output / f'{name}-store/versions'
    if not accepted and versions.exists() and any(versions.iterdir()):
        raise SystemExit(f'FAIL: rejected {name} patch was persisted')
    states[name] = state

evidence = {
    'hostEngineExecutionVerified': True,
    'targetPlatformExecutionVerified': [],
    'engineSha256': digest(Path(sys.argv[2])),
    'baselineSnapshotSha256': digest(output / 'artifacts/baseline.snapshot'),
    'patchSha256': patch_hash,
    'states': states,
    'logs': {name: (output / f'{name}.log').read_text()
             for name in ('baseline', 'signed', 'forged', 'mismatched')},
}
(output / 'engine-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
print('PASS: durable healthy state and empty rejected stores; Engine evidence recorded')
PY
echo 'PASS: actual AOT Flutter Engine mounted baseline and signed patched Text; forged signature and mismatched baseline failed open'
echo 'UNVERIFIED: Android/iOS/OHOS target execution and platform packaging'
