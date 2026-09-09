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

Five additional Engine dependencies were seeded from local Git objects with exact
revision checks: BoringSSL, protobuf, libc++, libc++abi and LLVM libc. The existing
Dart ICU checkout does **not** contain the Engine's pinned ICU revision and is
not reused. `seed_shared_deps.sh` repeats these checks/seeds and refuses to replace
existing mismatched repositories. Run it before a source sync.

## Reproduction and next gate

Start from isolated checkouts at the revisions above. If using a sparse Flutter
checkout, include `engine`, `bin` and `third_party` before installing build tools;
expanding sparse rules later may remove ignored tools outside those rules.
Place the Dart checkout
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
runtime. Track the live sync process and free space before proceeding. Range
probes confirmed `NO_PROXY=storage.googleapis.com,commondatastorage.googleapis.com`
can be used with the authorized HTTPS proxy for CIPD metadata, keeping binary
storage requests direct when that route is reachable.

The pinned GN and Ninja binaries have been installed and executed successfully:

| Tool | DEPS version | Immutable CIPD instance |
|---|---|---|
| GN | `81b24e01531ecf0eff12ec9359a555ec3944ec4e` | `UOt3zTOpG3ypEYMIj8Lmy9zIq5S8Jz25Si_ZVNLFy9oC` |
| Ninja | `2@1.11.1.chromium.4` | `ZFhjI422FVlCuVtH2KwXAzLNQ5UdS8j4kk7rGjDoxyMC` |

For the actual AOT gate use the release embedder target, not `flutter_tester`:
the latter directly depends on `libdart_jit`. The embedder instead uses
`flutter/runtime:libdart`, which selects the AOT runtime in release mode.
The first GN preflight reached repository-version validation and correctly
stopped at the not-yet-synced Skia source; it did not generate a complete build.

The next proof is an actual release Engine with `dart_dynamic_modules=true`
loading the repository's signed Widget DBC3 through Flutter, then target-specific
Android/iOS/OHOS builds. Source preparation, archive probes and a standalone Dart
VM must not be reported as that proof.

## Headless AOT harness (header gate passed, Engine execution pending)

`sh engine/check_headless_runner.sh` compiles `headless_aot_smoke.cc` against the
pinned C API header, checks that no Engine function is statically linked, and
rejects missing/unrelated libraries. This is a host compiler/loader-boundary
check, not a mocked Engine test or proof of DDM support.

Build target: `//flutter/shell/platform/embedder:flutter_engine`. The macOS
release binary is `out/<config>/FlutterEmbedder.framework/Versions/A/FlutterEmbedder`,
with `icudtl.dat` under `Versions/A/Resources`. After that build succeeds:

```text
headless_aot_smoke ENGINE_LIBRARY AOT_ELF ASSETS ICU TIMEOUT_SECONDS [DART_ARGS...]
```

The runner requires `RunsAOTCompiledDartCode`, initializes AOT ELF data, provides a
platform task queue and a 320×240 software surface, and enforces bounded timeouts
including native shutdown. Dart must send raw UTF-8 `PASS` (or `FAIL:<detail>`)
on `hotfix/runtime-smoke`; a genuine surface callback must also occur before
success. Frame FNV fingerprints are diagnostic, not cryptographic. The eventual
Dart fixture must independently assert signed-patch semantics; a PASS message
and a frame alone do not prove that the expected widget was patched.

The `flutter_compiled/main.dart` fixture is now wired to this protocol: after
`endOfFrame` it inspects the mounted `Text` child, checks baseline versus patched
content, and only then acknowledges signed-patch health and reports success.
No Dart arguments select baseline; three arguments select a signed patch; an
optional fourth `expect-baseline` argument supports a rejection case with a fresh
store. Its CFE/AOT artifact compilation is checked, but this complete fixture
has not yet been executed inside the new Engine.
