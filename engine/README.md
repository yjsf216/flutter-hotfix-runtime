# Isolated Flutter Engine DDM build

This is an in-progress **host verification toolchain**, not a fourth supported
application platform. Android, iOS and OHOS still need their own Engine builds
and packaging. No device or simulator is used by this preparation.

Pinned inputs:

| Input | Revision |
|---|---|
| Flutter 3.41.9 checkout | `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694` |
| Engine revision | `42d3d75a56efe1a2e9902f52dc8006099c45d937` |
| Engine content hash | `9161402dc0e134b3fb5adee5046b6e84b1a5e1c1` |
| Dart | `c70f78e7d682c158c15ca0c26c729b3ccb932284` |
| Engine Clang | `8c7a2ce01a77c96028fe2c8566f65c45ad9408d3` |

The installed standalone Dart build uses a different Clang revision
(`f77ce52b56d025399f489a8c0aad8c18c4b06045`). Do not silently reuse that compiler
as the Engine's pinned toolchain. `host-clang.ensure` pins the official immutable
CIPD instance for the Engine compiler.

## Current evidence

The pinned [Android DDM CI recipe](https://github.com/flutter/flutter/blob/3.41.9/engine/src/flutter/ci/builders/linux_android_aot_engine_ddm.json)
and [iOS DDM CI recipe](https://github.com/flutter/flutter/blob/3.41.9/engine/src/flutter/ci/builders/mac_ios_engine_ddm.json)
define the experimental archive names, but checking `android-arm64-release-ddm/artifacts.zip`
and `ios-release-ddm/artifacts.zip` under the pinned Engine revision and content
hash returned HTTP 404 on 2026-09-09. Ordinary archives exist; they are not
evidence of a DDM-enabled Engine. We therefore prepared a separate checkout at
`work/upstream/flutter-engine-ddm` rather than changing the user's FVM SDK.

The Flutter and Dart checkouts use local shared Git object stores. Dart's
already-resolved `third_party` and bootstrap SDK files were copied with macOS
APFS clone-on-write (`cp -cR`), not mutable hard links, and excluded from gclient
updates. These clones depend on the source Git object stores remaining available.
Source dependency synchronization is in progress; Engine compilation and linking
are **not yet verified**.

## Reproduction and next gate

Start from isolated checkouts at the revisions above. Place the Dart checkout
and its resolved dependencies at `engine/src/flutter/third_party/dart`, then
copy `host-ddm.gclient` to the isolated Flutter checkout as `.gclient`. The
configuration intentionally excludes Android SDK, web, Fuchsia, remote builds
and unused host toolchains during this first host gate. It never enables emulator
hooks. Run the existing depot_tools `gclient.py` with the system Python:

```sh
python3 /path/to/depot_tools/gclient.py sync \
  --nohooks --noprehooks --no-history --shallow --no-bootstrap \
  --ignore-dep-type=cipd --jobs=2
```

Use the already authorized HTTP/SOCKS proxy if Googlesource cannot be reached.
The separate source pass avoids downloading every CIPD payload while disk space
is constrained. Install only the pinned host Clang from `host-clang.ensure`;
resolve additional build tools from the exact DEPS/SDK hook requirements as GN
reports them. Do not run all hooks blindly or substitute the stock Flutter
runtime. Track the live sync process and free space before proceeding.

The next proof is an actual release Engine with `dart_dynamic_modules=true`
loading the repository's signed Widget DBC3 through Flutter, then target-specific
Android/iOS/OHOS builds. Source preparation, archive probes and a standalone Dart
VM must not be reported as that proof.
