# Security model

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
- Revocation and channel withdrawal are distinct: revocation distrusts a key/patch; withdrawal stops new assignment.
- Never log keys, tokens, full device identifiers, or downloaded code bytes.

## Threats explicitly tested

Tampered payload/manifest, replay/downgrade, cross-app/cross-channel/cross-ABI substitution, path traversal, symlink/TOCTOU swap, partial write, zip bomb if archives are introduced, manifest ambiguity, unknown key, local state corruption, boot loop, rollback suppression, CDN equivocation, and telemetry spoofing.

## Reporting

Do not publish exploit details or keys in an issue. Until a private address is established, report only that a security contact is needed and retain the evidence offline. A dedicated policy and response SLA must exist before any production claim.

