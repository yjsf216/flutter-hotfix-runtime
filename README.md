# Flutter Hotfix Runtime

Independent, self-hosted research and implementation of a signed Flutter Patch IR interpreter with bundled-baseline AOT linkage. This repository is **not production-ready**. Android is the host development platform; iOS and OHOS remain research targets.

## Current status

| Area | Status | Evidence required to advance |
|---|---|---|
| Manifest/security contract | P-256, frozen release identity, native transaction/fsync/no-follow store pass in host AOT; Android APK bundles native store | complete Engine/iOS/HAR integration, platform fault tests, trusted anti-replay and key operations |
| Android 3.41.9 baseline | host build verified | device validation is manual and not run by this task |
| Android external `libapp.so` | research/benchmark only | not a store production backend |
| Unified Patch IR Runtime | frozen release → automatic signed DBC3 → native store → AOT passes; real Flutter Widget AOT/DBC3 artifacts generated | Flutter Engine loading/rendering, remaining language lowering and platform gates |
| OHOS 3.27.5-ohos-1.0.5 | embedder path located | shared Runtime port after Android/iOS gates |
| iOS | dynamic-enabled VM core cross-compiles | Flutter Engine link and runtime execution |

## Reproduce the baseline

```sh
export FLUTTER_3419=/path/to/flutter/bin/flutter
cd spikes/android_spike
"$FLUTTER_3419" pub get
"$FLUTTER_3419" test
"$FLUTTER_3419" analyze
"$FLUTTER_3419" build apk --release --target-platform android-arm64
unzip -l build/app/outputs/flutter-apk/app-release.apk | grep libapp.so
```

Expected: tests and analysis pass and the APK contains `lib/arm64-v8a/libapp.so`. Device work is intentionally outside this task.

The host-only signing contract smoke test uses an ephemeral offline P-256 key:

```sh
sh spikes/android_spike/tool/signing_smoke.sh \
  spikes/android_spike/fixtures/patch-manifest.json \
  work/android-spike/patched/lib/arm64-v8a/libapp.so
```

## Patch IR semantic spike

The integrated compiler/runtime check is:

```sh
DART_BIN=/path/to/flutter/bin/cache/dart-sdk/bin/dart \
  sh spikes/patch_ir_spike/run_compiled_dbc3.sh
```

It compiles the baseline independently, compares real Kernel declarations,
clones changed methods and new private helpers into DBC3, and automatically
inserts AOT patch points before global optimization. OpenSSL signs the resulting
patch; the AOT process verifies P-256 with its embedded public key and exact
baseline identity, stages and reauthenticates the stored artifact, and activates
the generated FunctionId table. Tests cover fields, closures, named/optional
arguments, async, exceptions, nested AOT calls, withdrawal to baseline, forged
manifests and compiler rejection of incompatible/unsupported input.

The release and patch compiler phases are separate. A release folder stores
`baseline.input.dill`, `baseline.aot.dill`, `baseline.id`, its interface and
`release.json`; the patch phase needs those frozen files and updated source,
and checks compiler/platform identity before emitting bytecode. The integrated
test overwrites the source in place and removes the old application entry to
prove it does not rebuild the installed baseline. It also exercises the bundled
native file boundary described in [native/README.md](native/README.md).

For real Flutter Framework/dart:ui compilation without launching a device:

```sh
sh spikes/patch_ir_spike/run_flutter_kernel.sh
```

This generates a real AOT snapshot and one DBC3 Widget patch in a fresh output
directory. It does not claim Flutter Engine execution or rendering.

The earlier JSON semantic oracle remains a separate check:

```sh
DART_BIN=/path/to/flutter/bin/dart \
  sh spikes/patch_ir_spike/run.sh
```

This compiles ordinary Dart sources through the pinned Dart CFE/Kernel into stable metadata and Patch IR, injects method-entry patch points directly into Kernel AST, and compiles the transformed program to a native host executable. It verifies baseline/AOT and patch/interpreter paths plus mismatch rejection. A second native check covers SHA-256, atomic storage, pending boot, last-known-good, blacklist, withdrawal and disk tampering.

After building the pinned Dart source with `dart_dynamic_modules=true`, the
real DBC3/AOT bridge is checked with:

```sh
DART_SDK_SOURCE="$PWD/work/upstream/dart-sdk" \
  sh spikes/patch_ir_spike/run_dynamic_aot.sh
```

Expected: P-256 authenticated store activation and rejection of restart forgery,
plus GC/exception/async/isolate AOT↔interpreter PASS lines. This older bridge
fixture uses hand-written patch points; `run_compiled_dbc3.sh` covers automatic
generation.

The external `libapp.so` work is retained only as loading-chain research and an AOT performance baseline. It is not the Android store production backend.

See [TECHNICAL_ROUTE.md](TECHNICAL_ROUTE.md), [DYNAMIC_MODULES_AUDIT.md](DYNAMIC_MODULES_AUDIT.md), [OHOS_DYNAMIC_MODULES_AUDIT.md](OHOS_DYNAMIC_MODULES_AUDIT.md), [ARCHITECTURE.md](ARCHITECTURE.md), [PLAN.md](PLAN.md), [COMPATIBILITY.md](COMPATIBILITY.md), and [SECURITY.md](SECURITY.md).

## Explicit non-goals for now

- No dashboard, database, multi-tenant service, plugin abstraction, or custom CDN protocol.
- No claim that Android, OHOS, or iOS is supported before its real-device gate passes.
- No copying of unavailable Shorebird sources or inference about unpublished Shiply internals.
