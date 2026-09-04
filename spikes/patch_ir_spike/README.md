# Patch IR semantic spike

Host-only proof that ordinary Dart source can be assigned stable class/function IDs, diffed at method granularity, compiled to a tiny class-grouped IR, and dispatched between compiled baseline functions and an interpreter.

```sh
DART_BIN=/path/to/flutter/bin/dart sh run.sh
```

The parser intentionally supports only the fixture's static/instance methods, integers, strings, `+`, `>`, calls, branches, and returns. The signature token and baseline closures are explicit spike boundaries; platform cryptography and Dart frontend/AOT integration replace them in the next milestone.
