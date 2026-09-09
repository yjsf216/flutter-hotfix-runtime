# Patch IR spike evidence

## Frozen release / Flutter / native storage integration

- Separate release and patch phases pass after the old entry source is removed
  and business source is updated at the same original path. Baseline AOT, input
  Kernel and release descriptor are byte-for-byte unchanged; corrupted frozen
  Kernel and mismatched compiler fingerprints are rejected.
- File and package library identities preserve same-directory and `../` imports.
  AOT execution still returns the frozen dependency values after their on-disk
  sources are deliberately changed, proving the patch does not recompile them.
- URI-based parts now compile under their original library identity while a
  temporary in-memory Kernel copy isolates the frozen baseline. Tests change
  only a part, access private members across parts, and load successive versions
  in one AOT process (13 then 23). The whole CFE source-bundle digest changes
  module URI even when the main file is unchanged; identical inputs reproduce
  identical bytecode and frozen release files are never rewritten.
- A real Flutter target compiles a StatelessWidget/Text/dart:ui baseline to an
  AOT snapshot and one generated DBC3 module. Framework is retained only in the
  baseline. Loading/rendering in a Flutter Engine is still unverified.
- The signed generated-patch AOT test now uses bundled C file operations through
  Dart FFI. Eight concurrent isolate owners preserve all store updates, reject
  symlinks, and preserve a newly staged candidate across another boot's health
  acknowledgement.
- Health is tied to a unique durable boot attempt, not merely a patch ID.
  Delayed acknowledgements from another owner or the same loader's earlier
  asynchronous load preserve the newer pending token/failure count. Regression
  checks run in JIT, AOT, native FFI owners and the signed DBC3 loader; legacy
  state migration retains incomplete-boot evidence and LKG.
- Native ASan/UBSan tests cover concurrent read/replace, invalid path components,
  symlinks/hardlinks/FIFO, bounded reads, failed partial writes and a killed lock
  owner. The native helper compiles and links for Android/iOS/OHOS arm64; no
  device or simulator was used.
- Android Gradle/CMake packaging places the native store in the actual release
  APK; exported FFI symbols and 16 KiB segment alignment are checked from that
  APK. iOS arm64 final linkage retains all seven entries under dead stripping,
  with name-based lookup independently exercised on the host. OHOS CMake
  builds and exports the shared library; iOS app/HAR integration is pending.

## Integrated compiler and authenticated loader — 2026-09-09

Reproduce with `DART_BIN=/path/to/dart sh run_compiled_dbc3.sh`, using the
pinned dynamic-enabled host SDK build. The baseline is compiled independently
of the candidate. Its identity fingerprints the baseline Kernel, compiler
transform sources, AOT compiler binary and snapshot mode.

```text
PASS: ordinary Dart -> automatic patch points -> P-256 signed DBC3/store -> baseline AOT + rollback
PASS: forged generated patch manifest -> bundled baseline
PASS: generated field/closure/named/optional/async/exception/nested-call patch + rollback
PASS: incompatible source changes rejected before DBC3 emission
PASS: CFE rejects generator before bytecode emission
PASS: CFE rejects private-dynamic before bytecode emission
PASS: CFE rejects private-symbol before bytecode emission
PASS: CFE rejects super before bytecode emission
PASS: CFE rejects default-value before bytecode emission
```

`signature_check.dart` cross-checks OpenSSL-produced P-256 signatures and
rejects 43 adversarial envelopes, plus wrong/revoked public keys. The signed
store tests reject combined artifact/state/manifest tampering across restart;
explicit activation failure durably rejects its attempt and immediately tries a
distinct reauthenticated LKG. Real DBC3 tests cover success, a second failure,
duplicate module URI and rejection-write failure in separate AOT processes;
callbacks are bounded to two (one when persistence fails). Health requires the
load's owning coordinator and occurs after business checks. Unexplained process
death still leaves pending-boot evidence for the original failure threshold.

The compiler explicitly retains private baseline members, because upstream
library-wide dynamic-interface annotation skips them. The language fixture
reads a private field and calls a private AOT method unused in the baseline.

PatchStore now rejects ID overwrites and blacklisted reinstalls, preserves
failure accounting and LKG, bounds all file reads and returns the exact buffer
it authenticated. Sparse oversized files and a deterministic rewrite during
the verification callback test the read boundary.

The generated compiler still rejects unsupported language constructs and is a
host frontend driver. Flutter Engine integration, the OHOS compiler/runtime
build, platform execution/durability testing and trusted replay state remain
incomplete. These checks do not establish three-platform support.

## Historical separate spikes — 2026-09-04

Run on 2026-09-04 with Dart 3.11.5:

```text
Generated: .dart_tool/generated_runner
PASS: Dart CFE Kernel -> stable IDs -> one changed + one new method IR
PASS: Kernel compatibility rejects field layout and signature changes
PASS: baseline AOT bindings + changed interpreter dispatch
PASS: wrong baseline/signature/method signature/corrupt IR -> baseline
PASS: every release identity mismatch -> baseline
PASS: transformed AOT entry -> changed IR -> baseline AOT/new IR
PASS: SHA-256 + atomic files + pending boot + LKG + blacklist + withdrawal
PASS: invalid path/digest/state and disk tamper -> safe fallback
GAP: prebuilt AOT runtime has dart_dynamic_modules=false
PASS: custom dart_dynamic_modules=true AOT runtime loads and executes DBC3
PASS: verified store + GC/exception/async/isolate AOT <-> interpreted closures
PASS: observed scavenges while interpreted frames were live
PASS: upstream dynamic-module AOT suite 38/38
PASS: Android arm64 product VM cross-compiles with DART_DYNAMIC_MODULES
PARTIAL: iOS arm64 VM core compiles; standalone CLI target link conflicts
```

Verified properties:

- baseline and updated business sources contain no annotation, wrapper, proxy or registration;
- both ordinary sources are compiled to `.dill` by the Dart 3.11.5 CFE and read through upstream `package:kernel`;
- independent incompatible fixtures prove that added instance fields and changed existing method signatures are rejected before patch generation;
- stable `ClassId=26b195b7a2664f66`;
- stable changed `FunctionId=a9a6895bda6d60b5` and new static `FunctionId=9c0d7e351ec3d124`;
- exactly one method body changed and one patch-private static method was added, both grouped under their class in Patch IR;
- generated baseline bindings are compiled into a native host executable;
- the changed instance method executes IR, calls the unchanged static baseline method, then calls the new interpreted static method through dispatch;
- rejection is transactional: a bad candidate never replaces the active baseline table.
- appId, platform, ABI, release, Flutter/Dart/Engine revision, flavor, channel and build-parameter digest are each mutated independently and rejected before IR activation.
- a compiler-side Kernel AST transform injects patch checks into ordinary business methods, writes a new `.dill`, and compiles it to a native executable;
- the transformed instance AOT entry dispatches to changed IR; that IR calls both an unchanged baseline AOT static method and a new patch-private IR method; an unselected direct static call still executes its original AOT body.
- transformed Kernel inspection shows one compiler-injected `vm:never-inline` annotation and a `hotfixHasPatch`/`hotfixInvoke` entry guard on every patchable business method.
- the pinned upstream `dart2bytecode` AOT snapshot emits a 945-byte DBC3 v1 module from the fixture; the stock AOT runtime's explicit unsupported result proves a custom `dart_dynamic_modules=true` build is required.
- a custom macOS arm64 build of the exact pinned Dart revision with `DART_DYNAMIC_MODULES` enabled passes upstream `core_api`: the application is AOT-compiled, the module is validated and compiled to DBC3, and `dartaotruntime_product` loads and executes it through the KBC interpreter.
- the DBC3 module returns a `FunctionId -> closure` table; the AOT patch point invokes the interpreted closure, which calls a retained baseline AOT method. Unknown IDs are rejected before any candidate entry is activated.
- the real DBC3 loader is reached only after exact release identity, baselineId, byte length and SHA-256 checks; mismatched metadata and tampered bytes leave the AOT baseline active.
- valid DBC3 bytes are atomically staged, selected as pending boot, rehashed from final storage, activated, executed and only then marked healthy; tampering of the stored artifact selects bundled baseline.
- 20,000 interpreted calls allocate temporary objects while `--verbose-gc` confirms scavenges; the same module propagates an interpreted exception into AOT and completes interpreted async code that awaits and calls AOT.
- dynamic libraries are isolate-group scoped while dispatch globals are isolate-local; the main isolate loads once and sends the validated interpreted closure table to a child isolate, which starts on baseline and then executes the patch.
- a bounded concurrent churn runs 16 child isolates; each performs 1,000 synchronous interpreted calls, 10 async interpreted calls and an interpreted exception crossing before clean completion.
- all 38 upstream AOT dynamic-module semantic tests pass with zero failure logs; dedicated GC, exception, isolate and long-running async stress are not claimed by that suite.
- Android produces an AArch64 ELF PIE containing the dynamic loader, DBC3 bytecode reader and interpreter; no device was accessed and Flutter Engine integration remains unproven.
- iOS compiles the dynamic-enabled VM, bytecode reader and interpreter objects, then the standalone CLI target hits an exported/unexported-symbol-list linker conflict; only the real Flutter Engine link can close this gate.
- the pinned Flutter 3.41.9 Engine already supplies a `--dart-dynamic-modules` GN option, dedicated Android/iOS DDM CI builders and `-ddm` archive rules; no new Engine flag plumbing is required on those two platforms.
- the host store rehashes the final file before selection/health, detects disk tampering, rolls back after two incomplete boots, persists last-known-good and handles signed withdrawal input.

Deliberate spike limits: AOT entry bindings are generated Dart closures, new functions are static and patch-private, the signature token tests the verifier boundary rather than cryptography, and Kernel-to-IR opcodes cover only arguments, constants, integer/string addition, comparison, branch, call and return. The existing P-256 signing smoke separately verifies the cryptographic contract.
