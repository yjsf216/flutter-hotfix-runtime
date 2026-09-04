# Architecture

## Smallest system that can be safe

```text
offline private key -> signed immutable manifest + artifact -> object storage/CDN
                                                               |
app startup -> fetch candidate -> verify/bind -> atomic stage -> select -> Flutter Engine
                  failure ---------> last-known-good ----------^      |
                                     blacklist <--- boot state/crash --+
```

The private signing key is never present in the app or control plane. The initial control plane is only immutable objects plus a small signed channel manifest. A server is added only if static channel files cannot meet an audited rollout requirement.

## Patch identity

The signed manifest binds all fields below; absence or mismatch rejects the candidate before installation:

```json
{
  "schemaVersion": 1,
  "appId": "dev.hotfixruntime.android_spike",
  "platform": "android",
  "abi": "arm64-v8a",
  "release": "1.0.0+1",
  "flutterRevision": "00b0c91f06209d9e4a41f71b7a512d6eb3b9c694",
  "dartVersion": "3.11.5",
  "engineRevision": "42d3d75a56",
  "flavor": "production",
  "channel": "stable",
  "buildParametersSha256": "<64 lowercase hex>",
  "artifactSha256": "<64 lowercase hex>",
  "artifactSize": 0,
  "patchId": "monotonic-or-content-addressed-id",
  "issuedAt": "RFC3339 UTC",
  "revoked": false
}
```

Canonical signing format is UTF-8 JSON with recursively sorted keys, no insignificant whitespace, and integers only. The algorithm/key ID live in a signed envelope. Algorithm choice is held until the platform-native verification APIs are checked across the support floor; SHA-256 artifact hashing is fixed.

## Startup state machine

```text
BUNDLED -> STAGED -> PENDING_BOOT -> ACTIVE -> LAST_KNOWN_GOOD
                        |             |
                        +-- failure --+--> BAD/BLACKLISTED -> LAST_KNOWN_GOOD -> BUNDLED
```

Only a fully verified staged directory may be atomically renamed to `active`. `PENDING_BOOT` is written and fsynced before engine creation. Dart marks launch success only after the first frame plus an application health checkpoint. Repeated incomplete boots blacklist the patch. Server revocation prevents future selection but never deletes the only local known-good copy.

## Platform loading chains found

### Android first

Flutter 3.41.9 `FlutterLoader.ensureInitializationComplete` accepts `--aot-shared-library-name=<path>`, canonicalizes it, and permits only `.so` files beneath the app's internal files directory. It then appends bundled defaults. `SettingsFromCommandLine` preserves all supplied AOT paths and `DartSnapshot::SearchMapping` tries them in order, so the verified external path is preferred without reflection or an Engine fork. The spike must prove this on release devices before adopting it. If upstream behavior changes, the fallback is a small audited embedder API for verified mappings, not reflection.

### OHOS second

The public OpenHarmony-SIG loader constructs `--aot-shared-library-name` from `FlutterApplicationInfo`, passes shell args through N-API to `OhosMain::Init`, then calls `SettingsFromCommandLine`. It currently lacks the Android loader's canonical internal-path check. The first OHOS change should therefore be a narrow loader/embedder input for an already verified private path plus native canonical-path enforcement; device tracing must establish actual search order and HAP sandbox/dynamic-loader policy.

### iOS last

Stock Flutter loads signed AOT snapshot symbols from `App.framework`. Downloading new native instructions is out of scope. The independent runtime track must retain store-signed baseline AOT, represent changed functions as non-native interpreted data, and link unchanged functions back to baseline AOT while preserving Dart object layout, safepoints, stack maps, GC barriers, exceptions, isolates, async state machines, generics, FFI boundaries, and debugger/crash semantics. This is a Dart SDK/compiler/VM program, not an embedder flag.

## Public prior art and license boundary

Shorebird publicly describes baseline AOT plus an interpreter for changed iOS code and per-function reuse of baseline code. Public repositories expose mixed BSD-3-Clause, MIT, Apache-2.0/MIT, and file-specific licensing. Reuse is allowed only after recording the exact repository, commit, file license, attribution, and modifications. A missing/private `shorebirdtech/dart-sdk` is treated as unavailable: design starts from upstream `dart-lang/sdk`; behavior may be independently reproduced from public descriptions, never copied from inaccessible code.

Shiply material is used only as product inspiration for staged rollout, approval, telemetry, circuit breaking, and rollback. No runtime mechanism is inferred from marketing or secondary articles.

## Sources (retrieved 2026-09-04)

- [Flutter 3.41.9 Android FlutterLoader](https://github.com/flutter/flutter/blob/3.41.9/engine/src/flutter/shell/platform/android/io/flutter/embedding/engine/loader/FlutterLoader.java)
- [Flutter AOT operation](https://github.com/flutter/flutter/blob/3.41.9/docs/engine/Flutter-engine-operation-in-AOT-Mode.md)
- [Flutter snapshot resolver](https://github.com/flutter/flutter/blob/3.41.9/engine/src/flutter/runtime/dart_snapshot.cc)
- [OpenHarmony-SIG FlutterLoader.ets](https://gitee.com/openharmony-sig/flutter_engine/blob/master/shell/platform/ohos/flutter_embedding/flutter/src/main/ets/embedding/engine/loader/FlutterLoader.ets)
- [OpenHarmony-SIG OhosMain](https://gitee.com/openharmony-sig/flutter_engine/blob/master/shell/platform/ohos/ohos_main.cpp)
- [Shorebird system architecture](https://docs.shorebird.dev/code-push/system-architecture/)
- [Shorebird engineering licensing philosophy](https://handbook.shorebird.dev/departments/engineering/)
- [Apple App Review Guidelines 2.5.2](https://developer.apple.com/app-store/review/guidelines/)
- [Shiply public site](https://shiply.tds.qq.com/)

