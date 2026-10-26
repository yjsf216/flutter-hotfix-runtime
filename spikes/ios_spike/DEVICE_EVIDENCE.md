# iOS device AOT/DBC3 verification

## Management/Git business-app loop: 2026-10-14

A real business Flutter application (not the standalone fixture) completed the
management HTTP API → Git-selected baseline → development-signed IPA → later
Git-selected two-file Dart patch → publish → LAN download → next cold-start
activation → health report → signed withdrawal → baseline fallback loop on an
authorized iPhone 15 running iOS 18.7.2. Flutter 3.41.9 and the matching custom
iOS arm64 Release/AOT/DDM Engine were used. Existing business plugins and native
channels were retained; strict signing and archive integrity checks passed.

Only the initial baseline required installation. No uninstall, data clearing,
patch-container injection or patch-time reinstall was performed. Persisted
state confirmed the active/LKG patch and zero failures after activation. The
business startup diagnostic confirmed a rasterized first frame, mounted
navigation, no captured startup errors and completion of the update check.
After withdrawal, active/LKG were null and the withdrawn patch was blacklisted;
another healthy baseline event reached the delivery server.

Private evidence: `work/ios-business-20261014/` contains baseline, downloaded,
patched and withdrawn startup/state JSON. The private delivery server retains
the corresponding received events. Business identifiers, signing material and
device identities are intentionally not copied into public documentation.

The two changed UI components also passed Widget tests against their Git
revision. This was not an on-device screenshot comparison, browser click-through
test, exhaustive business regression, or App Store distribution approval.

## Revalidation: 2026-10-13

An authorized iPhone 15 running iOS 18.7.2 passed the baseline, signed Widget
DBC3 activation, cold restart, forged-signature fallback and wrong-baseline
fallback cases. The native Release host was rebuilt with Xcode 26.5 using the
existing custom Engine and frozen AOT App.framework. Automatic development
signing registered this device; the user explicitly trusted the developer on
the phone. Strict recursive code-signature verification passed.

The old September manifest had expired. A new manifest was signed with the
original test key and current validity dates; expiration checks were not
disabled. The original baseline and bytecode digests below were reused. The
valid case produced a new `PASS` result with active/LKG `p1`, null pending and
zero failures both initially and after process termination/relaunch. Both
negative cases produced `PASS` baseline with null active/LKG and empty digests,
using current-dated manifests so expiration could not mask the tested failure.

Private artifacts: `work/ios-current-validation/`, including `baseline-result.txt`,
`first/`, `restart-complete/`, `invalid/` and `wrong/`. Only the dedicated
`dev.hotfixruntime.ios-spike` app was installed and launched; no business app
was replaced, and no app data was cleared.

This revalidation transferred patch inputs through the development app
container. It does **not** revalidate network delivery, the latest compiler on
arbitrary application sources, management-console iOS integration, or App Store
distribution. Those remain separate gates; this is not a production-support
claim.

## Initial verification: 2026-09-10

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

Remaining work includes production remote deployment, signing/policy review,
broader Dart semantics, performance, crash/fault coverage on iOS, and more devices.
This finite matrix does not make the full hotfix runtime production-ready.
