# Dart 3.11.5 dynamic modules audit

Pinned Dart SDK revision: `c70f78e7d682c158c15ca0c26c729b3ccb932284`, taken from Flutter 3.41.9 `DEPS`.

## Reusable upstream implementation

The upstream SDK already contains the hard VM mechanisms this project needs:

- `pkg/dart2bytecode`: CFE/Kernel to DBC3 bytecode compiler;
- `pkg/dynamic_modules`: `loadModuleFromBytes` and `loadModuleFromUri` API;
- `runtime/vm/bytecode_reader.*`: validates and materializes bytecode declarations and code;
- `runtime/vm/interpreter.*`: KBC interpreter;
- `DartEntry::InvokeFunction`: routes interpreted functions to `Interpreter::Call` in an AOT runtime;
- `Interpreter::InvokeCompiled`: calls installed AOT entry points from bytecode;
- interpreter entry frames, exception longjmp/unwind, suspended async locations and `VisitObjectPointers` for GC.

All are guarded by `DART_DYNAMIC_MODULES`. The GN argument `dart_dynamic_modules` defaults to `false`; the packages are explicitly marked experimental, unpublished and not included as a supported SDK API.

## Host evidence

The Flutter 3.41.9 SDK ships an AOT `dart2bytecode.dart.snapshot`. It successfully compiles the ordinary fixture into a 945-byte DBC3 format-version-1 module. The installed product AOT runtime then rejects loading with:

```text
Unsupported operation: Loading of dynamic modules is not supported.
```

The same pinned Dart source was then built for macOS arm64 with
`--dart-dynamic-modules`. The build emitted `dart`, `gen_snapshot`,
`dartaotruntime_product`, `gen_kernel_aot.dart.snapshot` and
`dart2bytecode.dart.snapshot` with `DART_DYNAMIC_MODULES` enabled. The upstream
`core_api` AOT test completed the full path:

```text
ordinary Dart -> Kernel with dynamic interface -> AOT ELF
dynamic Dart module -> validated DBC3 bytecode
AOT host -> loadModuleFromBytes -> KBC interpreter
Test results:
  core_api: Status.pass
```

This proves the pinned VM can execute downloaded non-machine-code DBC3 inside
an AOT process and cross the AOT/interpreter boundary. It does not yet prove
Flutter Engine integration or Android, iOS, or OHOS support.

The repository's `run_dynamic_aot.sh` adds the hotfix-specific bridge: a DBC3
entry point returns a validated `FunctionId -> closure` table, an existing AOT
method calls the interpreted closure, and that closure calls a retained AOT
method. A malformed table is rejected transactionally before activation. The
same executable rejects a mismatched release manifest and SHA-256/length disk
tampering before calling the experimental loader, while continuing baseline.
Valid bytes pass through the atomic PatchStore, pending-boot selection and a
second on-disk digest check before activation; health is committed only after
the interpreted bridge executes.

The complete upstream AOT dynamic-module suite also passes: 38/38 tests with
zero failure logs. It covers constants, closures, checked invocation, records,
mixins, enums, repeated loading, generics, extension types, inheritance and
module type checks. The hotfix bridge additionally survives 20,000 interpreted
allocating calls with 21 observed scavenges, propagates an interpreted exception
to AOT and completes interpreted async code that calls AOT. Isolate and
long-running async stress remain separate product gates.

Reproduction uses a Dart SDK source checkout at the pinned revision:

```sh
python3 tools/build.py --mode release --arch arm64 --no-rbe \
  --dart-dynamic-modules --exclude-kernel-service -j8 runtime
buildtools/ninja/ninja -C xcodebuild/ReleaseARM64 \
  gen/gen_kernel_aot.dart.snapshot gen/dart2bytecode.dart.snapshot
xcodebuild/ReleaseARM64/dartaotruntime_product --disable-dart-dev \
  xcodebuild/ReleaseARM64/gen/gen_kernel_aot.dart.snapshot --target vm \
  --packages .dart_tool/package_config.json --no-aot \
  --platform xcodebuild/ReleaseARM64/vm_platform.dill \
  --output pkg/dynamic_modules/test/runner/work_dynamic_runner.dill \
  pkg/dynamic_modules/test/runner/main.dart
xcodebuild/ReleaseARM64/dart \
  pkg/dynamic_modules/test/runner/work_dynamic_runner.dill \
  --runtime=aot --test=core_api --verbose
cd <flutter-hotfix-runtime>
DART_SDK_SOURCE=<dart-sdk-source> \
  sh spikes/patch_ir_spike/run_dynamic_aot.sh
```

With macOS 26 SDK, the pinned source additionally needs
`-Wno-deprecated-declarations` because its `readdir_r` calls otherwise fail the
old build's `-Werror` policy. This is a host-toolchain compatibility workaround,
not a Runtime behavior change.

## Platform cross-compile evidence

Flutter 3.41.9 Engine already exposes `tools/gn --dart-dynamic-modules`, maps it
to `dart_dynamic_modules=true`, and contains dedicated DDM builders for Android
arm64/x64 release/debug plus iOS device/simulator release/debug. Its archive
rules add the `-ddm` suffix. Therefore no custom GN plumbing patch is needed for
Android or iOS; the project should reuse this experimental upstream build path.

Android arm64 product `dartaotruntime` builds successfully from the pinned
source with `DART_DYNAMIC_MODULES`. The result is an AArch64 ELF PIE targeting
`/system/bin/linker64`; static inspection contains `Internal_loadDynamicModule`,
`bytecode_reader.cc`, `interpreter.cc` and DBC3 format diagnostics. It has not
been installed or run on a device and is not yet a Flutter Engine build.

iOS arm64 compiles the same dynamic-enabled VM, bytecode reader and interpreter
objects successfully. The standalone command-line `dartaotruntime` target then
fails to link because its generic rule passes both exported- and unexported-
symbol lists to current `ld64.lld`. Flutter embeds the VM through different
Engine targets, so the honest iOS status is “core compiles; real Engine link
still required,” not platform support.

## Product adaptation still required

Upstream dynamic modules add new module declarations; they do not automatically replace an existing baseline method. This project retains its compiler-generated FunctionId patch points and maps them to loaded DBC3 functions. The dynamic-interface YAML becomes an allowlist for which baseline libraries, classes and members Patch IR may call or extend.

Required work:

1. Build the Flutter-pinned Engine with `dart_dynamic_modules=true` for Android, iOS and OHOS; host execution and Android cross-compilation pass, while iOS has only passed core compilation.
2. Replace the temporary JSON opcode interpreter with DBC3 modules.
3. Generate the proven `FunctionId -> interpreted closure` table from real Kernel diffs; unpatched IDs keep the installed AOT entry.
4. Preserve the existing signed manifest, strong release binding, atomic store and boot rollback outside the experimental loader.
5. Add isolate and long-running async stress before Flutter tests; the 38-test upstream suite plus host GC/exception/basic-async bridge gates pass.
6. Vendor only exact pinned BSD-licensed upstream source changes and assume breaking changes on every Dart upgrade.

## Stop conditions

- `DART_DYNAMIC_MODULES` cannot be built in Flutter product AOT for a target platform;
- upstream loader requires JIT or writable executable memory;
- interpreted/compiled transitions fail GC, exception, isolate or async stress tests;
- dynamic interface cannot prevent undeclared native/plugin/FFI access;
- Apple, Google Play or OHOS policy review rejects the resulting behavior.
