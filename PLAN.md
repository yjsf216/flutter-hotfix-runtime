# Delivery plan

Every phase ends in a continue/stop decision. Passing source review or an emulator is not platform support.

## M0 — contract and reproducibility (now)

- Pin Flutter 3.41.9 / Dart 3.11.5 / Engine `42d3d75a56` for Android and iOS research.
- Pin Flutter OHOS 3.27.5-ohos-1.0.5 / Dart 3.6.2 / OHOS Engine `75252a6e5a748d29251ac16cd8d37a0e8f01729f` (`engine.ohos.version`, not the upstream Android/iOS engine.version).
- Freeze manifest canonicalization, binding fields, offline-signing procedure, and evidence format.
- Build/install the Android marker baseline.

**Accept:** clean checkout runs test/analyze/build and records exact revisions and `libapp.so`; an authorized operator later records an arm64 device displaying `BASELINE`.  
**Stop:** target SDK cannot reproducibly build or packaged AOT identity cannot be derived.

## M1 — host Patch IR semantic spike (passed)

- Parse ordinary baseline/updated Dart fixtures without annotations or wrappers.
- Generate stable ClassId/FunctionId, baseline metadata, a method-level diff, and minimal class-grouped Patch IR with a patch-private new function.
- Dispatch unchanged functions to baseline implementations and changed functions to the interpreter.
- Reject bad signature, baselineId, method signature, and malformed IR while continuing baseline.

**Accept:** one host command compiles/runs the spike and proves every case; business fixtures contain no hot-update marker.
**Stop:** stable identity or method-level replacement requires business-source instrumentation.

## M2 — Dart frontend and AOT patch points (host entry transform passed)

- Integrate the Kernel transform into the frontend pipeline. **Host driver passed:** `compileToKernel` → exact AST diff/clone → DBC3 plus patch points → `runGlobalTransformations` → AOT; Flutter's shipping frontend remains to be connected.
- **Release/patch split passed:** release freezes input Kernel, AOT Kernel, identity and interface policy; patch validates and imports those artifacts without recompiling the baseline, including after in-place source replacement and removal of the old entry point.
- **Relative dependency gate passed:** file/package candidate aliases retain same-directory and parent-relative imports; AOT execution proves frozen dependencies are reused after their disk sources change. URI-based `part of` libraries still need identity handling.
- **Real Flutter artifact gate passed:** `target=flutter` with the installed product `dart:ui` platform compiles a changed `StatelessWidget.build` into one DBC3 module, retains Framework in a real AOT snapshot and leaves frozen release files unchanged. Engine rendering/loading remains unverified.
- Build the pinned host VM with `dart_dynamic_modules=true` and execute generated DBC3. **Passed:** upstream `core_api` AOT dynamic-module test.
- Map FunctionId patch points to interpreted closures and installed AOT entries. **Host bridge passed:** `AOT -> DBC3 closure -> AOT`, including transactional rejection.
- Run the complete upstream dynamic-module AOT semantic suite. **Passed:** 38/38, zero failure logs.
- Cross-compile the dynamic-enabled standalone VM. **Android arm64 passed; iOS core objects passed but the non-Engine command-line target has an export-list link conflict.**
- Reuse Flutter Engine's existing DDM GN/CI route. **Confirmed:** pinned 3.41.9 already defines Android and iOS DDM builders and archives; no new flag plumbing is needed.
- Join verification/storage with the real loader. **Passed:** identity, length and digest gate → atomic store → pending boot → rehash → DBC3 activation → healthy commit; tampering stays baseline.
- **Real authentication passed:** OpenSSL P-256 signatures verified inside AOT with embedded keys, complete release identity and independently compiled baseline fingerprint. Startup reauthenticates the stored manifest and the exact bytes returned to the loader; state+artifact+manifest forgery is rejected.
- **Automatic compiler corpus passed:** same-layout fields, local closures, named/optional arguments, async, exceptions, retained nested AOT calls and rollback. Generics, generators, lexical `super`, dynamic calls, new classes and constructor updates still require implementation; unsupported inputs fail compilation.
- Disable cross-function inlining only for updateable business packages.
- Implement AOT↔interpreter bridges, then object/async/exception/GC/isolate gates. **Host GC, exception, async and 16-isolate bounded churn passed; multi-hour platform soak remains.**

**Accept:** ordinary Dart compiles without business instrumentation; generated AOT patch points route both directions; the semantic corpus and performance budget pass.
**Stop:** stable linkage requires manual business registration, or patch points impose unacceptable baseline overhead.

## M3 — Android production integration

- Embed the shared Runtime in Flutter 3.41.9 Android.
- Add signing, atomic install, startup state, last-known-good, blacklist and withdrawal.
- **Native file boundary passed on host:** bundled C `openat/O_NOFOLLOW`, descriptor reads, file/directory fsync, renameat and directory-inode transactions are connected to the signed Dart loader. C libraries cross-compile/link for Android/iOS/OHOS arm64; app/Engine packaging and platform power-loss tests remain.
- **Native packaging gate partially passed:** Android Gradle/CMake release APK contains the arm64 store and seven FFI exports with 16 KiB segment alignment. Apple CMake consumers retain those exports under dead stripping; an iOS arm64 executable cross-links, and OHOS CMake produces the shared library. Full iOS/Flutter HAR packaging and target execution remain unverified.
- Run compatibility, performance, crash rollback and Google Play policy gates.

**Accept:** host integration tests plus an independently authorized Android device matrix pass baseline, valid patch, corrupt patch, mismatch and crash rollback scenarios.
**Stop:** Google Play review rejects the interpreter model, engine revision is ambiguous, or recovery is unreliable.

## M4 — iOS port, then OHOS port

- Port the already-tested shared IR/interpreter/linker core to iOS without downloaded machine code.
- Pass App Review/legal, GC, exception, isolate, Flutter and performance gates.
- Port the same core through the OHOS ArkTS/N-API embedder and repeat the corpus.
- **OHOS source gate passed:** its pinned Dart 3.6.2 already contains DBC3/KBC, and the Engine's existing `--gn-args` path accepts `dart_dynamic_modules=true`; arm64 HAR build remains pending.

**Accept feasibility:** no downloaded machine code; deterministic linker; semantic parity corpus passes on each platform; overhead and patch size meet explicit budgets; store/legal gates are positive.
**Stop:** any correctness gap in GC/exception/isolate safety, required private Shorebird source, unacceptable performance, or policy rejection.

## Deferred until demanded

Backend APIs, UI console, RBAC, multi-tenancy, databases, and complex approvals stay out. Static signed manifests and object storage are enough until measured rollout/audit needs prove otherwise.
