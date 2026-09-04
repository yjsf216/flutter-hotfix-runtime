# Delivery plan

Every phase ends in a continue/stop decision. Passing source review or an emulator is not platform support.

## M0 — contract and reproducibility (now)

- Pin Flutter 3.41.9 / Dart 3.11.5 / Engine `42d3d75a56` for Android and iOS research.
- Pin Flutter OHOS 3.27.5-ohos-1.0.5 / Dart 3.6.2 / Engine `e672b006cb` for OHOS.
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

- Integrate the proven external Kernel transform into the upstream Dart frontend pipeline.
- Build the pinned host VM with `dart_dynamic_modules=true` and execute generated DBC3. **Passed:** upstream `core_api` AOT dynamic-module test.
- Map FunctionId patch points to interpreted closures and installed AOT entries. **Host bridge passed:** `AOT -> DBC3 closure -> AOT`, including transactional rejection.
- Run the complete upstream dynamic-module AOT semantic suite. **Passed:** 38/38, zero failure logs.
- Disable cross-function inlining only for updateable business packages.
- Implement AOT↔interpreter bridges, then object/async/exception/GC/isolate gates.

**Accept:** ordinary Dart compiles without business instrumentation; generated AOT patch points route both directions; the semantic corpus and performance budget pass.
**Stop:** stable linkage requires manual business registration, or patch points impose unacceptable baseline overhead.

## M3 — Android production integration

- Embed the shared Runtime in Flutter 3.41.9 Android.
- Add signing, atomic install, startup state, last-known-good, blacklist and withdrawal.
- Run compatibility, performance, crash rollback and Google Play policy gates.

**Accept:** host integration tests plus an independently authorized Android device matrix pass baseline, valid patch, corrupt patch, mismatch and crash rollback scenarios.
**Stop:** Google Play review rejects the interpreter model, engine revision is ambiguous, or recovery is unreliable.

## M4 — iOS port, then OHOS port

- Port the already-tested shared IR/interpreter/linker core to iOS without downloaded machine code.
- Pass App Review/legal, GC, exception, isolate, Flutter and performance gates.
- Port the same core through the OHOS ArkTS/N-API embedder and repeat the corpus.

**Accept feasibility:** no downloaded machine code; deterministic linker; semantic parity corpus passes on each platform; overhead and patch size meet explicit budgets; store/legal gates are positive.
**Stop:** any correctness gap in GC/exception/isolate safety, required private Shorebird source, unacceptable performance, or policy rejection.

## Deferred until demanded

Backend APIs, UI console, RBAC, multi-tenancy, databases, and complex approvals stay out. Static signed manifests and object storage are enough until measured rollout/audit needs prove otherwise.
