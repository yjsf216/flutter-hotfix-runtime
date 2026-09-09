# Isolated Flutter Engine DDM build

The **host Engine verification gate has passed**; this is not a fourth supported
application platform. Android, iOS and OHOS still need their own Engine builds,
packaging and execution gates. No device or simulator is used here.

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
Source synchronization for the selected host embedder target has completed.
The matching Clang package is installed; `clang --version` reports revision
`8c7a2ce01a77c96028fe2c8566f65c45ad9408d3`, and CIPD's installed receipt matches
`host-clang.ensure`. The host release Engine compiled and linked with `-j2` and
passed the four-process signed Widget/negative-input matrix. See
[the execution evidence and exact fingerprints](EVIDENCE.md).

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

Apply `engine/patches/host_clang_plist.patch` with `git apply` from the isolated
Flutter checkout root before configuration. It fixes an observed build failure:
the upstream plist script hardcodes an x64 Clang path even on an arm64 host.
All three plist callers now pass GN's actual host compiler path, respecting
`host_cpu` and `buildtools_path`; neither another toolchain nor a compatibility
symlink is required. The host wrapper checks that this patch is present.
The patched plist action has executed successfully in the actual Ninja build.

That build later stopped at offline Metal shader compilation because the installed
Xcode lacks the Metal Toolchain. The **host software-surface harness only** now
disables `shell_enable_metal`, `impeller_enable_metal` and desktop application
embeddings. GN checks still require AOT/DDM and `embedder_enable_software=true`;
the actual selected command graph contains no offline Metal compilation. The
real Engine build resumed successfully with existing objects and Skia software rendering.
This does not validate Metal/GPU behavior or change either mobile configuration:
the iOS production build still needs its Metal Toolchain.

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

Later preflights passed Skia/version validation and reached pending Vulkan
headers. A critical upstream flag interaction was reproduced: in this pinned
`tools/gn`, `--no-enable-unittests` overwrites `dart_dynamic_modules` with false.
`configure_host_ddm.sh` avoids that flag and checks GN's effective DDM/release/CPU
values after successful generation. The initial Metal-enabled generation passed all three
effective-value checks and produced 1,124 targets; the selected AOT library also
defines `DART_DYNAMIC_MODULES`, `PRODUCT` and `DART_PRECOMPILED_RUNTIME`.
A Ninja dry-run of the actual
embedder target resolved 3,962 actions and its graph includes the AOT runtime,
not the JIT runtime or SwiftShader. SwiftShader is therefore excluded only from
this host-target dependency configuration. These are configuration/dependency
checks, not evidence of native compilation or Engine execution.

The copied Dart checkout's package config and SDK version have been generated,
and the macOS SDK links prepared with `darwin_sdk.py --sdk macosx` only. To free
build space, 7,937 old standalone Dart `.o`/`.a` files were removed from four
object directories, preserving their `.ninja` rules and all final compiler,
runtime, snapshot and evidence files. The three core binary SHA-256 values were
unchanged, and the signed dynamic AOT/LKG regression passed afterward. These
intermediate objects can be regenerated from the retained build configuration.

The actual host release Engine has now loaded the signed Widget DBC3 through
Flutter. The next gates are target-specific Android/iOS/OHOS builds and execution;
neither this host gate nor a standalone Dart VM establishes those results.

## Headless AOT harness (actual software Engine gate passed)

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
success. Frame FNV fingerprints are diagnostic, not cryptographic. The
Dart fixture independently asserts signed-patch semantics; a PASS message
and a frame alone do not prove that the expected widget was patched.

The `flutter_compiled/main.dart` fixture defers the first frame during patch
bootstrap, then checks the mounted `Text` after `endOfFrame`. It releases that
validated frame and waits for `waitUntilFirstFrameRasterized` before acknowledging
signed-patch health, preventing an empty bootstrap frame or UI-only completion
from satisfying the checkpoint.
No Dart arguments select baseline; three arguments select a signed patch; an
optional fourth `expect-baseline` argument supports a rejection case with a fresh
store. Both its CFE/AOT compilation and the four actual Engine runs have passed.

`sh engine/run_host_ddm.sh` wires this fixture to the real built embedder. It
reuses the existing frozen-release compiler and offline signer, embeds a fresh
test public key, and runs four separate processes against the same AOT snapshot:
baseline, signed patch, forged signature, and a correctly signed manifest for a
different baseline. Each process must produce a frame and pass the mounted Text
assertion; the signed case must also commit native-store health. Logs and test
artifacts stay under a unique ignored `work/engine-ddm-check.*` directory.
After all four runs, the script verifies durable state: the signed patch is active
and last-known-good with no pending attempt; rejected patches have no active
version, digest or persisted artifact. `engine-evidence.json` records these
states, Engine/snapshot/patch SHA-256 values and all four logs, separately from the
compiler-only `flutter-evidence.json` whose scope is artifact generation.

## iOS arm64 cross-build preflight

The same isolated checkout now also generates an iOS **device-architecture**
release configuration; no device or simulator is contacted or started. From
`engine/src`:

```sh
export PATH="$PWD/../../../depot_tools:$PATH"
export VPYTHON_BYPASS='manually managed python not supported by chrome operations'
python3 build/mac/darwin_sdk.py --sdk iphoneos --print-paths
python3 flutter/tools/gn --ios --runtime-mode=release --no-lto \
  --no-prebuilt-dart-sdk --no-full-dart-sdk --no-build-engine-artifacts \
  --dart-dynamic-modules --allow-deprecated-api-calls \
  --target-dir=hotfix_ios_release_arm64 --gn-args=enable_unittests=false
../../third_party/ninja/ninja -n -C out/hotfix_ios_release_arm64 \
  flutter/lib/snapshot:generate_snapshot_bins \
  flutter/shell/platform/darwin/ios:flutter_framework
```

On 2026-09-09 the installed iPhoneOS 26.5 SDK resolved successfully and GN's
effective values were `target_os="ios"`, `target_cpu="arm64"`,
`use_ios_simulator=false`, `flutter_runtime_mode="release"`, and
`dart_dynamic_modules=true`. The AOT runtime defines include
`DART_TARGET_OS_MACOS_IOS`, `PRODUCT`, `DART_PRECOMPILED_RUNTIME`, and
`DART_DYNAMIC_MODULES`. The two official iOS release targets resolve 6,563
Ninja actions in dry-run mode. Native iOS compilation, linking, signing and
runtime execution are **not yet verified**; this is not an iOS support claim.

## Android arm64 cross-build preflight

The native Android configuration requires NDK `28.2.13676358`, SDK platform 36
and build-tools `36.1.0`. All three match installed components. Independent APFS
clone-on-write copies are now under `engine/src/flutter/third_party/android_tools/sdk`
(`ndk/28.2.13676358`, `platforms/android-36`, `build-tools/36.1.0`). The NDK copy
came from the task's Dart checkout; the other two came from the installed Android
SDK. No user SDK file is modified and no mutable hard links or directory symlinks
point into it. This is a selected-component seed, not the full Android CIPD bundle.

Apply `engine/patches/android_host_clang.patch` from the isolated Flutter checkout
root. The Android GN toolchain also hardcoded `mac-x64`; the patch selects
`mac-$host_cpu`, using the installed, pinned Engine Clang rather than the NDK's
different compiler. From `engine/src`, with the environment exports above:

```sh
python3 flutter/tools/gn --android --android-cpu=arm64 --runtime-mode=release \
  --no-lto --no-prebuilt-dart-sdk --no-full-dart-sdk --no-build-engine-artifacts \
  --dart-dynamic-modules --allow-deprecated-api-calls \
  --target-dir=hotfix_android_release_arm64 --gn-args=enable_unittests=false
../../third_party/ninja/ninja -n -C out/hotfix_android_release_arm64 \
  flutter/shell/platform/android:flutter_shell_native \
  flutter/lib/snapshot:create_macos_gen_snapshot_arm64_arm64
```

Effective GN values confirm Android/arm64/release/DDM. The runtime defines include
`DART_TARGET_OS_ANDROID`, `DART_COMPRESSED_POINTERS`, `DART_DYNAMIC_MODULES`,
`PRODUCT` and `DART_PRECOMPILED_RUNTIME`. The selected targets resolve 5,603
actions, producing `libflutter.so` and `artifacts_arm64/gen_snapshot_arm64`.
A canary compile of `obj/flutter/fml/command_line.command_line.o` has executed
successfully and produced an AArch64 ELF object. Full native linking, matching
snapshot generation, APK integration and target execution are still unverified.
Full Java/archive builds additionally need the pinned OpenJDK and Android
embedding dependencies; the native preflight does not claim those are installed.
