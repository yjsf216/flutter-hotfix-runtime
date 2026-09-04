# Patch IR spike evidence

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
PASS: identity/digest fail-open + FunctionId AOT -> interpreted closure -> baseline AOT
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
- all 38 upstream AOT dynamic-module semantic tests pass with zero failure logs; dedicated GC, exception, isolate and long-running async stress are not claimed by that suite.
- Android produces an AArch64 ELF PIE containing the dynamic loader, DBC3 bytecode reader and interpreter; no device was accessed and Flutter Engine integration remains unproven.
- iOS compiles the dynamic-enabled VM, bytecode reader and interpreter objects, then the standalone CLI target hits an exported/unexported-symbol-list linker conflict; only the real Flutter Engine link can close this gate.
- the pinned Flutter 3.41.9 Engine already supplies a `--dart-dynamic-modules` GN option, dedicated Android/iOS DDM CI builders and `-ddm` archive rules; no new Engine flag plumbing is required on those two platforms.
- the host store rehashes the final file before selection/health, detects disk tampering, rolls back after two incomplete boots, persists last-known-good and handles signed withdrawal input.

Deliberate spike limits: AOT entry bindings are generated Dart closures, new functions are static and patch-private, the signature token tests the verifier boundary rather than cryptography, and Kernel-to-IR opcodes cover only arguments, constants, integer/string addition, comparison, branch, call and return. The existing P-256 signing smoke separately verifies the cryptographic contract.
