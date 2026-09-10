# Android startup / DBC3 device evidence

Authorized device only: `ANDROID_DEVICE_SERIAL`, Android 16 / API 36, arm64-v8a.
Package: `dev.hotfixruntime.android_spike`. No other device was used.
Updates used `adb -s ANDROID_DEVICE_SERIAL install -r`, preserving application data; the
previous APK is retained at `work/phone-bootstrap.rbynzB/previous.apk`.

This is a **development-signed, debuggable APK with Release/AOT Dart and the
custom Android Engine**, not Flutter debug/JIT or a production distribution.
The debug-only `hotfix_test_case` extra selects one of four fixed directories.
Production/default selection uses the app's own `files/hotfix` directory.
No untrusted absolute path is accepted from the intent or manifest.

## Verified matrix

| Case | Mounted Text | Durable result |
|---|---|---|
| No patch | `Flutter: baseline` | PASS |
| Valid P-256 signed DBC3 | `Flutter: patched` | active/LKG `p1`, pending null |
| Valid patch after cold restart | `Flutter: patched` | active/LKG `p1`, pending null |
| Cold restart with inbox moved aside | `Flutter: patched` | cached active/LKG `p1`, pending null |
| Forged signature | `Flutter: baseline` | null active/LKG, empty digests |
| Signed for another baseline | `Flutter: baseline` | null active/LKG, empty digests |

The shared Dart fixture checks the actual mounted Text, holds the first-frame
gate, waits for Engine rasterization, then marks the patch healthy. Logs identify
the actual Vulkan/Impeller backend. This is not an independent pixel screenshot
comparison. `PASS` alone in automatic mode is insufficient: each patch result
was also checked against the durable store and expected artifact digest.

Evidence is retained under `work/phone-bootstrap.rbynzB`: per-case
`*-final.log`, `*-result.txt`, `*-state.json`, signed test envelopes and
`native-diagnostic-artifacts`. Private test keys are ignored and not shipped.
The cached-only check is retained in `cached-final.log` and `cached-state.json`;
its inbox was moved back afterward, with no test data deleted.

Final APK: `work/phone-bootstrap.rbynzB/final.apk`, SHA-256
`3d9e3e076801454e123ee2e345cd4439844f36260f4c503e3b3f93805c42a88a`.
Signature verification and 16 KiB ZIP alignment passed. The AOT and Engine
payloads were checked byte-for-byte against staged inputs before the final
Kotlin-only cached-startup change; no Dart or Engine rebuild followed that check.

Frozen baseline ID:
`117c82ef9e84ff167c1e69acd6303c340c52d3394aab7ab3c4fae811872ad138`

Baseline AOT SHA-256:
`8b260962588c8ab6a71562c855ea1cdd3fb30c3681573a0ba962225bec13cfe3`

DBC3 SHA-256:
`7f5a599148eac8dbc48e21ae3368193f94b2ba6345ab7b49bfc14adc6580fa2e`

## Root cause and scope

The app process resolves `/data/user/0/...` to `/data/data/...`; inspecting
the path from `adb run-as` did not reproduce that namespace alias. The native
no-follow directory walk correctly rejected the alias with `ENOTDIR`.
The activity now canonicalizes only Android's trusted `filesDir` base before
constructing fixed child paths. No-follow checks remain in the native store.
Linux search-only directory descriptors also allow execute-only ancestors,
without skipping final-directory permissions or durability checks.

Re-run native regression checks with `sh native/run_patch_store_io_check.sh`.
The Linux execute-only regression needs a non-root Linux process; macOS does
not exercise that branch. Host checks and the Android device startup passed.

This does not prove remote delivery, production signing, multiple Android
vendors, performance, arbitrary Dart changes, iOS execution or OHOS support.
