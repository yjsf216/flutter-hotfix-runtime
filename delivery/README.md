# Minimal patch delivery loop (development MVP)

Implemented: compile signed DBC3 → authenticated upload + local file storage →
app check/download → next-start activation → result reports. No management site,
database, cloud account or production deployment is required.

Both Android and iOS physical devices passed the online two-start loop; see
[evidence](EVIDENCE.md). This is development validation, not App Store approval.

## Commands

Run from the repository root. Use the existing pinned Flutter/Dart SDKs and
custom target-specific `gen_snapshot`; never substitute the stock Engine.
`dart` below means `/path/to/flutter/bin/cache/dart-sdk/bin/dart`.

### 1. Build the network-enabled base app once

Use the existing `spikes/patch_ir_spike/run_flutter_kernel.sh` with:

```sh
HOTFIX_TEST_PUBLIC_KEY="$(cat /path/to/signing/public-key.txt)" \
HOTFIX_NATIVE_STORE=true \
HOTFIX_UPDATE_ORIGIN=https://patches.example.com \
HOTFIX_APP_ID=dev.hotfixruntime.android_spike HOTFIX_PLATFORM=android \
GEN_SNAPSHOT=/absolute/path/to/android/gen_snapshot_arm64 \
sh spikes/patch_ir_spike/run_flutter_kernel.sh /absolute/path/to/new-baseline
```

For iOS set `HOTFIX_APP_ID=dev.hotfixruntime.ios-spike`, `HOTFIX_PLATFORM=ios`,
use the iOS generator, and package Apple AOT assembly into App.framework as in
the existing iOS host. Keep each platform's frozen release and package config.
The embedded origin, trust anchor, app/platform identity and native-store mode
are part of the baseline build; changing them requires a new base app.

The current compiler harness targets the existing `flutter_compiled` example;
arbitrary-project onboarding and unsupported Dart changes are not solved here.

### 2. Generate a patch without rebuilding the release

```sh
dart --packages=work/upstream/dart-sdk/.dart_tool/package_config.json \
  spikes/patch_ir_spike/tool/compile_flutter_patch.dart \
  work/upstream/dart-sdk /path/to/flutter \
  /absolute/path/to/target/gen_snapshot_arm64 \
  /absolute/path/to/baseline/release \
  spikes/patch_ir_spike/fixtures/flutter_compiled/updated.dart \
  /absolute/path/to/new-patch /absolute/path/to/baseline/package_config.json

dart -DHOTFIX_APP_ID=dev.hotfixruntime.android_spike -DHOTFIX_PLATFORM=android \
  spikes/patch_ir_spike/tool/signature_check.dart sign \
  /path/to/signing /absolute/path/to/new-patch/patch.bytecode \
  /absolute/path/to/manifest.json FROZEN_BASELINE_ID unique-patch-id
```

The existing offline `signature_check.dart keygen DIRECTORY` creates development
P-256 keys. The signing machine retains the private key; upload never sends it.
The signer app/platform values must match the baseline; the client rejects a
different identity. Test manifests expire after one day. IDs are immutable:
retry publication using the exact same envelope, not a newly signed replacement.

### 3. Start the service and upload

Set `HOTFIX_PUBLISH_TOKEN` to a secret of at least 24 characters, loaded from a
protected environment/secret file, not a shell argument. Never embed it in apps.

```sh
dart spikes/patch_ir_spike/tool/delivery_server.dart \
  /absolute/path/to/server-storage /path/to/signing/public-key.txt

# In another terminal, with the same publishing token:
dart spikes/patch_ir_spike/tool/delivery_publish.dart \
  https://patches.example.com /absolute/path/to/manifest.json \
  /absolute/path/to/new-patch/patch.bytecode
```

The service defaults to `127.0.0.1:8080`; put it behind your own HTTPS terminator
for remote use. `HOTFIX_BIND` / `HOTFIX_PORT` override its listen address/port.
It is a single-process development server: one process per storage directory.
Use an operator-owned directory; it is not hardened against local disk writers.

For explicit local testing only, set `HOTFIX_ALLOW_DEV_HTTP=true` in both the
baseline compilation environment and publisher environment. Android's test
manifest allows HTTP only to `127.0.0.1` (used with device-specific adb reverse).
The iOS test host declares local-network usage. Do not ship development HTTP
configuration or expose the development service directly on the public Internet.

## API

| Endpoint | Purpose |
|---|---|
| `POST /v1/releases` | Bearer-authenticated JSON upload of base64 `envelope` and `artifact`; verifies signature/hash, commits blob then latest pointer; 201 |
| `GET /v1/check?baselineId=SHA256` | Exact baseline's canonical signed envelope, or JSON `null`; 200 |
| `GET /v1/blobs/SHA256` | Content-addressed bytecode; client validates signed size/hash before install |
| `POST /v1/reports` | Bounded `{baselineId, patchId, outcome}` observation; appends server timestamp to `reports.jsonl`; 202 |

Upload limits: 16 KiB signed envelope, 8 MiB artifact. Unauthorized upload returns
401, invalid signature/content 422, conflicting immutable envelope 409. Latest
publication selects a candidate for that baseline only; it is not a command to
switch a running process. Files use temp-write/flush/rename. Partial/orphaned
server files cannot make clients execute unauthenticated bytes.

## Client startup semantics

1. Load/revalidate the locally selected candidate and run the page.
2. Verify the mounted Text and first rasterized frame, then commit startup health.
3. Report `baseline_healthy` or `patch_healthy`, check the service, bound download
   time/size and reject redirects, wrong identities, signatures or digests.
4. Install complete signed bytes through the existing native transactional store.
   Report `downloaded`; the running dispatch table and page are unchanged.
5. On the next process startup, load and health-check the candidate normally.

The store field `active` means selected for startup; after download it may be the
new candidate while the currently displayed page still runs baseline/LKG. Only
the next successful startup commits `lastKnownGood` for that candidate.

## Checks and explicit limits

```sh
dart spikes/patch_ir_spike/tool/delivery_check.dart
ruby spikes/ios_spike/check_project.rb
sh engine/run_host_ddm.sh
```

The HTTP regression uses real loopback sockets and a store, but a test callback
instead of Flutter module execution. Device evidence separately proves AOT/DBC3
execution. It checks auth, upload retry, corruption, wrong baseline, signatures,
offline fail-open, next-start-only activation and server receipt of reports.

Deliberately deferred: management website, cloud storage, rollout buckets,
server-driven withdrawal, multi-process publication, key rotation UI, resumable
downloads and production rate limiting. Reports are unauthenticated observations
and never control activation; they contain no user/device identifier. Reporting
is best effort (no persistent offline outbox or crash-report retry), and the
collector rejects further reports after its log exceeds 10 MiB. Successful
startup is reported; fatal process crashes still rely on existing local recovery.
Add durable telemetry and lifecycle management before production deployment.
