# Delivery plan

Every phase ends in a continue/stop decision. Passing source review or an emulator is not platform support.

## M0 — contract and reproducibility (now)

- Pin Flutter 3.41.9 / Dart 3.11.5 / Engine `42d3d75a56` for Android and iOS research.
- Pin Flutter OHOS 3.27.5-ohos-1.0.5 / Dart 3.6.2 / Engine `e672b006cb` for OHOS.
- Freeze manifest canonicalization, binding fields, offline-signing procedure, and evidence format.
- Build/install the Android marker baseline.

**Accept:** clean checkout runs test/analyze/build and records exact revisions and `libapp.so`; an authorized operator later records an arm64 device displaying `BASELINE`.  
**Stop:** target SDK cannot reproducibly build or packaged AOT identity cannot be derived.

## M1 — Android external AOT selection

- Build `BASELINE` and `PATCHED` release AOT with identical pinned inputs.
- Add the minimum pre-engine verifier/atomic installer/selector.
- Pass external-library path directly to `FlutterEngine`; no reflection.
- Add scripted baseline, valid patch, corrupt patch, crash rollback, and mismatch scenarios.

**Accept:** two physical devices pass every scenario across three clean runs; no unverified byte reaches `dlopen`; offline/network failure launches within the agreed startup budget.  
**Stop:** loader policy forbids app-private executable mappings on supported Android versions, revisions cannot be bound reliably, or rollback cannot recover a boot loop.

## M2 — Android production hardening

- Key rotation/revocation, deterministic rollout bucket, signed channel withdrawal.
- Telemetry schema for selection, verification, boot success, crash, rollback; privacy review.
- Reproducible engine/embedder build only if M1 proves upstream embedding insufficient.
- Store-policy/legal review and operational runbook.

**Accept:** adversarial tests, rollback drill, audit trail, staged rollout gate, and support matrix sign-off.  
**Stop:** policy review rejects executable patching or operational evidence is insufficient.

## M3 — OHOS loading spike and hardening

- Trace ArkTS `FlutterLoader` -> N-API -> `OhosMain::Init` -> settings -> snapshot symbols.
- Add canonical app-private-path enforcement and reuse the manifest/state-machine contract.
- Produce repeatable HAP build/install/baseline/patch/corrupt/crash/mismatch scripts.

**Accept:** physical HarmonyOS/OpenHarmony targets pass the same safety matrix and marketplace review is cleared.  
**Stop:** signed HAP sandbox/loader policy rejects executable `libapp.so`, engine revision is ambiguous, or recovery is unreliable.

## M4 — iOS feasibility, then implementation only if viable

- Fork upstream Dart SDK at the engine-pinned revision; build a tiny baseline/delta corpus.
- Define stable function identity and object-layout compatibility.
- Prototype changed-function interpreter plus AOT linkage for pure Dart first.
- Expand gates: closures/generics/async, GC/safepoints, exceptions, isolates, then FFI.
- Obtain written App Review/legal interpretation before production rollout.

**Accept feasibility:** no downloaded machine code; deterministic linker; semantic parity corpus passes; overhead and patch size meet explicit budgets; store/legal gate is positive.  
**Stop:** any correctness gap in GC/exception/isolate safety, required private Shorebird source, unacceptable performance, or policy rejection.

## M5 — desktop and Web expansion

- Reuse the verified release contract and state machine for Windows/Linux AOT artifacts.
- Split macOS into Developer ID and Mac App Store execution policies.
- Use ordinary versioned JS/Wasm deployment and Service Worker rollback for Web.

**Accept:** each target has a reproducible build, platform-native install/update path, rollback drill, and distribution-policy review.
**Stop:** platform signing or sandbox requirements require weakening default runtime protections.

## Deferred until demanded

Backend APIs, UI console, RBAC, multi-tenancy, databases, and complex approvals stay out. Static signed manifests and object storage are enough until measured rollout/audit needs prove otherwise.
