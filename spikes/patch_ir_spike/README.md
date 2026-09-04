# Patch IR semantic spike

Host-only proof that ordinary Dart source can be compiled by the pinned Dart CFE to Kernel, assigned stable class/function IDs, diffed at method granularity, compiled to a tiny class-grouped IR, and dispatched between compiled baseline functions and an interpreter.

```sh
DART_BIN=/path/to/flutter/bin/dart sh run.sh
```

The Kernel-to-IR compiler intentionally supports only the fixture's static/instance methods, integers, strings, `+`, `>`, calls, branches, and returns. It pins the Dart SDK source revision from Flutter 3.41.9. The signature token and generated baseline closures are explicit spike boundaries; platform cryptography and native AOT entry linkage replace them in the next milestone.

The same command also compiles and runs the host patch-store check: SHA-256, atomic file replacement, final-file rehash, `PENDING_BOOT`, last-known-good, two-failure blacklist, withdrawal, tamper detection and bundled fail-open.
