# Patch IR spike evidence

Run on 2026-09-04 with Dart 3.11.5:

```text
Generated: .dart_tool/generated_runner
PASS: Dart CFE Kernel -> stable IDs -> one-method Patch IR
PASS: baseline AOT bindings + changed interpreter dispatch
PASS: wrong baseline/signature/method signature/corrupt IR -> baseline
```

Verified properties:

- baseline and updated business sources contain no annotation, wrapper, proxy or registration;
- both ordinary sources are compiled to `.dill` by the Dart 3.11.5 CFE and read through upstream `package:kernel`;
- stable `ClassId=26b195b7a2664f66`;
- stable changed `FunctionId=a9a6895bda6d60b5`;
- exactly one method body changed and is grouped under its class in Patch IR;
- generated baseline bindings are compiled into a native host executable;
- the changed instance method executes IR and calls the unchanged static baseline method through dispatch;
- rejection is transactional: a bad candidate never replaces the active baseline table.

Deliberate spike limits: AOT entry bindings are generated Dart closures, the signature token tests the verifier boundary rather than cryptography, and Kernel-to-IR opcodes cover only arguments, constants, integer/string addition, comparison, branch, call and return. The existing P-256 signing smoke separately verifies the cryptographic contract.
