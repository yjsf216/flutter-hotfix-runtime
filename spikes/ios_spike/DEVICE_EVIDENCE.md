# iOS device AOT/DBC3 verification

Verified on authorized iPhone (iPhone 6s, iOS 15.8.7), USB UDID
`IOS_DEVICE_UDID`, on 2026-09-10.
Only `dev.hotfixruntime.ios-spike` was installed/launched. Personal Team
`PERSONAL_TEAM_ID` was explicitly authorized and the user trusted its developer on
the phone. No app uninstall or app-data clearing was performed.

## Results

| Case | Result and durable state |
|---|---|
| Baseline | Mounted baseline Text / first-frame gate PASS |
| Signed Widget DBC3 | PASS; active/LKG `p1`, pending null, zero failures |
| Cold restart | PASS; active/LKG `p1` |
| Inbox moved aside, cached-only restart | New result file PASS; active/LKG `p1` |
| Forged signature | PASS baseline; null active/LKG, empty digests |
| Valid signature for another baseline | PASS baseline; null active/LKG, empty digests |

The shared Dart fixture checks the actual mounted Text, then waits for the first
rasterized frame before committing patch health. Automatic-mode PASS was also
checked against persisted state and exact patch digest. This is not a screenshot
pixel comparison or a proof of all Dart semantics.

Retained audit: `work/ios-device.wrQCNc`. Files `valid-result.txt`,
`invalid-signature-result.txt`, `wrong-baseline-result.txt`, `cached-result.txt`
and corresponding `*-state.json` contain the fetched app-private results.
The cached test renamed its old result before restart to exclude stale success;
the inbox was restored afterward. The signed app is retained as
`verified-HotfixRuntime.app`. Tests after the initial baseline used native
Release configuration and the custom Release/AOT/DDM Engine, not Flutter JIT.

Frozen baseline ID:
`af10834c826cf54ce3c2d06ec1cab7eca1e22195b75ea246cd7b2f5c6dfa45e8`

DBC3 SHA-256:
`18c8028b10f0c97e32a14d34ce90b194cc28bb024a53fd8b90c8384b1575933e`

Signed App.framework/App SHA-256:
`d229444e303f4bd36235e2ad80b2af7c9f986dc1d40e2e9a57a52eca8f0d844a`

Signed Flutter.framework/Flutter SHA-256:
`86daaa4d0346d9325b1847434742c494a712b0fb61624c5025f25f5513f233dd`

Signed host executable SHA-256:
`362bf0491079aeb5394967f5d99fe378167f6a39ec0adff2bc2a600dd891d741`

Strict recursive codesign verification passed. Signing changes Mach-O metadata,
so whole-file equality with unsigned inputs is not expected; every file-backed
Mach-O section in App/Flutter was compared and matched its staged counterpart.
The host exports all seven store FFI symbols and the trusted base initializer.

## Fixes required by actual device execution

1. Register the channel after Engine.run; iOS asserts when a handler is set first.
2. Use POSIX realpath for the trusted Documents base: Foundation preserved /var.
3. Pin that app-owned base once before starting runtime threads. iOS sandbox
   rejects traversing /private even with search-only open flags. All candidate
   roots must be below the pinned base; every child component retains no-follow,
   owner/mode, inode-lock and durability checks. No arbitrary manifest path can
   initialize or replace this base. Runtime-wide base registration is immutable.

`sh native/run_patch_store_io_check.sh` passed ASan/UBSan path, symlink, hardlink,
FIFO, concurrency, partial-write and new immutable-base/outside-root tests, plus
iOS arm64 cross compilation. `device_files.c` uses installed libimobiledevice
for narrowly scoped USB app-container transfer; its `--self-check` accesses no
device and checks the path boundary. Private test keys remain in ignored work.

Remaining work includes remote delivery, production signing/policy review,
broader Dart semantics, performance, crash/fault coverage on iOS, and more devices.
This finite matrix does not make the full hotfix runtime production-ready.
