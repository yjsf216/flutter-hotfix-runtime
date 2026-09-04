# Architecture

## Smallest system that can be safe

```text
offline private key -> signed manifest + Patch IR -> object storage/CDN
                                                               |
app startup -> fetch candidate -> verify/bind -> atomic stage -> dispatch -> AOT/interpreter
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

### Unified execution backend

All three platforms ship baseline AOT, the pinned upstream DBC3/KBC dynamic-module runtime, stable class/function metadata, a dispatch table, and AOT↔interpreter bridges. The customized frontend/compiler inserts patch points automatically; business Dart remains ordinary source. Unchanged functions use bundled AOT and changed/new functions use signed non-machine-code bytecode.

### Android first

Android is the development and debugging host for the shared Runtime. External `libapp.so` remains a loading-chain experiment and performance baseline only; Google Play production uses Patch IR because Play prohibits downloading `.so`, `.dex`, and `.jar` outside Play while conditionally allowing VM/interpreter execution.

### iOS last

Stock Flutter loads signed AOT snapshot symbols from `App.framework`. The shared Runtime retains store-signed baseline AOT, interprets changed functions from Patch IR, and links unchanged functions back to baseline AOT while preserving Dart object layout, safepoints, stack maps, GC barriers, exceptions, isolates, async state machines, generics, FFI boundaries, and debugger/crash semantics. No downloaded machine code is allowed.

### OHOS last

OHOS receives the same Patch IR and Runtime semantics through its ArkTS/N-API embedder. The public external `libapp.so` chain is retained only for research; production does not depend on writable executable mappings.

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
