# Patch IR compiler and runtime checks

`DART_BIN=/path/to/dart sh run_compiled_dbc3.sh` is the integrated host proof:
ordinary Dart → upstream Kernel comparison/clone → generated AOT patch points
and DBC3 → OpenSSL P-256 signing → authenticated store/loader → interpreted
functions calling retained baseline AOT → health commit and rollback.

Release and patch are separate compiler phases: frozen input/AOT Kernel and
identity are saved once; patches can be generated after replacing the original
source and removing its entry point. The integrated check uses the bundled
native transactional store, including cross-isolate contention.
It also proves file/package relative imports reuse frozen AOT dependencies
after both the business source and dependency sources change on disk.

`sh run_flutter_kernel.sh` additionally compiles an ordinary Flutter
`StatelessWidget.build` with the real product `dart:ui` platform into a retained
baseline AOT snapshot and one DBC3 module. It checks frozen-release integrity;
it does not launch a Flutter Engine or claim rendered output.

It requires the pinned dynamic-enabled Dart source build under `work/upstream`.
Compiler-side tools use that SDK's workspace package config. Business fixtures
are ordinary Dart; Runtime setup belongs to the application entry point.
Unsupported shapes are rejected, including changed layout/signature/defaults,
generic methods/classes, generators, dynamic calls and lexical `super` calls.
URI-based `part of` libraries are supported without rewriting business source:
the frozen Kernel library is temporarily renamed in memory, while CFE sees the
candidate's real logical URI. Module identity hashes the actual source bundle,
so changing only a part still produces a distinct loadable module.

`DART_BIN=/path/to/dart sh run_dynamic_aot.sh` separately stresses the real
signed loader with hand-written dispatch fixtures, GC, exceptions, async and
16 concurrent isolates. `dart tool/signature_check.dart` verifies the signing
contract against OpenSSL and adversarial inputs.

## Earlier JSON oracle

Host-only proof that ordinary Dart source can be compiled by the pinned Dart CFE to Kernel, assigned stable class/function IDs, diffed at method granularity, compiled to a tiny class-grouped IR, and dispatched between compiled baseline functions and an interpreter.

```sh
DART_BIN=/path/to/flutter/bin/dart sh run.sh
```

The earlier Kernel-to-JSON compiler intentionally supports only the fixture's static/instance methods, integers, strings, `+`, `>`, calls, branches, and returns. Its signature token is only an oracle stub; the integrated DBC3 checks above use real P-256 verification.

The build also transforms the CFE Kernel AST to inject method-entry patch points, serializes the transformed `.dill`, and compiles it to a native executable. The executable proves `AOT entry -> changed IR -> unchanged baseline AOT/new IR` plus an unselected direct AOT path, without changing the business source.

The same command also compiles and runs the host patch-store check: SHA-256, atomic file replacement, final-file rehash, `PENDING_BOOT`, last-known-good, two-failure blacklist, withdrawal, tamper detection and bundled fail-open.

It additionally checks that the stock Flutter SDK AOT runtime reports `dart_dynamic_modules=false`. The integrated checks use the custom dynamic-enabled Runtime for positive execution.
