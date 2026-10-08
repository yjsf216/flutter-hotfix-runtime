# Security model

**Experimental, not independently security-audited or production-ready.**
The sections below include design requirements and historical checkpoints.
For current device scope see `spikes/ios_spike/DEVICE_EVIDENCE.md` and
`delivery/EVIDENCE.md`. The delivery service is development-only; reports are
unauthenticated observations and must never drive activation. The phase-three
loader adds private stable rollout buckets, signed patch withdrawal and a bounded
durable report outbox. See `GIT_WORKFLOW.md` for the new-base requirement, limits
and acceptance scope. App Store acceptance is not established by device tests.

Network, CDN, manifest storage, downloaded bytes, local disk, clocks, and process termination are untrusted. The app-embedded public-key set and bundled AOT are trust anchors; the offline private key is outside the runtime system.

## Mandatory checks before selection

1. Parse with size/depth limits; reject duplicate/unknown critical fields and non-canonical encodings.
2. Verify signature over the canonical manifest envelope with an embedded, non-revoked key ID.
3. Compare every identity field to values embedded by the release build.
4. Stream SHA-256 and byte-count the artifact; compare both without following symlinks.
5. Stage in an app-private directory, fsync file and directory, then atomic rename.
6. Re-open and re-hash the final inode immediately before engine creation; prevent path traversal and link swapping.
7. Persist `PENDING_BOOT` before launch; only an authenticated, expected patch ID can become last-known-good.

Failure at any step is fail-open for app availability and fail-closed for the candidate: launch last-known-good, otherwise bundled AOT.

## Rollback rules

- Bundled AOT is never deleted.
- One last-known-good version remains until a newer version completes the health checkpoint.
- An incomplete boot counts as failure; threshold starts at 2 for the spike and remains configurable only if production data justifies it.
- Bad patch IDs are locally blacklisted for the release. A newer signed manifest may revoke them but cannot silently clear local failure evidence.
- Rollout selection is deterministic from a privacy-preserving install bucket; manifest signature covers percentage, channel, patch ID, and expiry.

## Key operations

- Generate and use signing keys offline or in an approved HSM/KMS signing boundary.
- Embed at least current and next public keys; signed metadata identifies the key.
- Rotation requires an app release unless the next key was pre-embedded.
- Distribution pause stops new assignment; signed patch withdrawal permanently
  denies that patch ID after the client receives it, switching on next startup.
- Never log keys, tokens, full device identifiers, or downloaded code bytes.

## Verified host checks and remaining work

The current host Runtime verifies OpenSSL-produced ECDSA P-256/SHA-256 signatures
using a pinned pure Dart PointyCastle implementation. The embedded key set,
algorithm and every identity field are enforced; canonical JSON equality rejects
duplicate keys and alternate encodings. Tests cover invalid/unknown/revoked
keys, signed identity mismatches, expiry/schema/DER errors, artifact tampering,
and combined artifact/state/manifest forgery after restart. Bounds are 16 KiB
for manifests, 64 MiB for artifacts and 1 MiB for store state.

Store tests cover immutable IDs, preserved LKG, pending-boot failure accounting,
blacklist, withdrawal, damaged state, symlinks, oversized sparse files, and
returning the exact authenticated buffer even if disk changes during validation.
An explicit VM/activation failure atomically rejects that exact boot attempt and
selects a distinct, reauthenticated LKG. A second failure, duplicate module URI,
or failed rejection persistence falls back to bundled without a retry loop.
Unexplained process death still uses the two-incomplete-boot threshold. Stale
callback failures cannot reject a newer attempt or invoke its dispatch rollback;
application activation must still be scheduled by one startup coordinator, since
arbitrary callback side effects cannot be undone by the store.
Only the owning loader can acknowledge a completed load as healthy. Each boot
persists a fresh 128-bit attempt token; health also requires the original local
capability and an exact match with the current durable attempt. Delayed health
from an earlier same-ID boot or another owner cannot erase a newer pending
boot's failure evidence. Legacy state migration preserves that evidence.

The bundled native store now implements component-wise `openat/O_NOFOLLOW`,
single-descriptor bounded reads, file and directory fsync, renameat and a
directory-inode lock around the whole state transaction. It is connected to
the P-256 loader via Dart FFI; both inbound files and stored files use native
descriptor reads when enabled. Host sanitizer/fault/concurrency tests and
Android/iOS/OHOS arm64 cross-linking pass. The original pure Dart backend stays
available only as the earlier test oracle and does not provide these primitives.

The Android spike release APK now bundles the native store with all seven FFI
exports. Shared CMake Apple linkage keeps those exports under dead stripping;
an iOS arm64 executable is cross-linked but not run. OHOS CMake exports pass,
but the shared library is not yet packaged into a Flutter HAR.

Still required: complete Engine/iOS app/OHOS HAR integration and runtime checks,
platform power-loss and filesystem fault injection, trusted anti-replay/downgrade
state and production deployment operations. Local expiry alone is not trusted
anti-replay. Healthy-expiry exemption relies on the persisted app-private LKG
marker, not hardware-authenticated rollback state: an adversary controlling local
state or clocks can replay formerly signed compatible code. Signatures still
prevent unauthenticated code, and received withdrawal/failure evidence persists
under the ordinary app-private storage assumption. Hardware-backed anti-rollback,
key rotation operations, production access controls/rate limits and independent
security review remain required before a production-security claim.

Host regressions cover signed partial rollout thresholds and monotonic expansion,
pause/resume, permanent signed withdrawal, strict expired admission versus healthy
LKG reuse, interrupted downloads, persisted reports, idempotent ingestion and
recovery of an incomplete report-log tail. These do not establish full platform
power-loss durability or trustworthy user counts. Reports carry random event IDs,
not account/device IDs; the grouping salt stays local. Queues/logs are explicitly
bounded and do not control startup health.

## Reporting

Do not publish exploit details or keys in an issue. Until a private address is established, report only that a security contact is needed and retain the evidence offline. A dedicated policy and response SLA must exist before any production claim.
