# OHOS dynamic modules audit

Pinned Flutter OHOS SDK: `3.27.5-ohos-1.0.5`.

| Component | Revision |
|---|---|
| Flutter OHOS SDK | `d9cf54be36c1151910c70498919f430dadad217e` |
| OHOS Engine (`engine.ohos.version`) | `75252a6e5a748d29251ac16cd8d37a0e8f01729f` |
| Dart from Engine `DEPS` | `42f3fc1c648bc66e56c822a95e6139bb116020c3` (3.6.2) |

## Finding

The pinned Dart 3.6.2 source already contains `pkg/dart2bytecode`,
`pkg/dynamic_modules`, `runtime/vm/bytecode_reader.*`, the KBC interpreter and
the `DART_DYNAMIC_MODULES` guarded AOT bridges. Its DBC3 format version is 1,
and `dart_dynamic_modules` defaults to `false` just as it does in Dart 3.11.5.

The pinned OHOS Engine does not expose the later dedicated
`--dart-dynamic-modules` switch, but its `tools/gn` appends repeated
`--gn-args` values verbatim. Therefore the first OHOS build experiment needs no
VM backport and no Engine abstraction:

```sh
python3 flutter/tools/gn \
  --ohos --ohos-cpu arm64 --runtime-mode release \
  --gn-args=dart_dynamic_modules=true
ninja -C out/ohos_release_arm64 \
  flutter/shell/platform/ohos:flutter_har_zip
```

The OHOS build uses `flutter/runtime:libdart`, which selects Dart's
`libdart_precompiled_runtime` in release mode. The platform archive target
packages `flutter.har` and the native engine libraries, so static inspection of
that final archive—not a standalone Dart executable—is the correct build gate.

## Status and remaining gates

- Source gate passed: the exact pinned Dart revision contains DBC3/KBC and the
  OHOS Engine can receive `dart_dynamic_modules=true` through existing GN args.
- Build gate pending: sync the OHOS Engine `DEPS_ohos`, build the arm64 release
  HAR, and verify the loader/interpreter symbols in its native library.
- Runtime gate pending: an independently authorized operator must later run the
  same signed FunctionId bridge corpus; this task does not access devices.
- DBC3 is compiled separately for each strongly bound Dart/Engine release even
  though both pinned revisions currently report format version 1.
