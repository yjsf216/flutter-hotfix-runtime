# Flutter Hotfix Runtime

Independent, self-hosted research and implementation of a signed Flutter/Dart runtime patch path. This repository is **not production-ready**. The current deliverable is a reproducible Android baseline and a source-backed plan; Android external AOT loading, OHOS, and iOS remain unverified on device.

## Current status

| Area | Status | Evidence required to advance |
|---|---|---|
| Manifest/security contract | designed | verifier tests, tamper tests, key rotation test |
| Android 3.41.9 baseline | host build verified | device validation is manual and not run by this task |
| Android external `libapp.so` | source path confirmed, device test next | signed patch displays `PATCHED`; corrupt/mismatched patch falls back |
| OHOS 3.27.5-ohos-1.0.5 | loader path located | HAP/device trace proves selected `libapp.so` |
| iOS | research only | interpreter/linker feasibility gate passes |

## Reproduce the baseline

```sh
export FLUTTER_3419=/path/to/flutter/bin/flutter
cd spikes/android_spike
"$FLUTTER_3419" pub get
"$FLUTTER_3419" test
"$FLUTTER_3419" analyze
"$FLUTTER_3419" build apk --release --target-platform android-arm64
unzip -l build/app/outputs/flutter-apk/app-release.apk | grep libapp.so
adb devices -l
adb -s DEVICE_SERIAL install -r build/app/outputs/flutter-apk/app-release.apk
adb -s DEVICE_SERIAL shell am force-stop dev.hotfixruntime.android_spike
adb -s DEVICE_SERIAL shell monkey -p dev.hotfixruntime.android_spike 1
```

Expected: tests and analysis pass and the APK contains `lib/arm64-v8a/libapp.so`. The `adb` lines are operator-only acceptance commands; this task does not access connected devices.

The host-only signing contract smoke test uses an ephemeral offline P-256 key:

```sh
sh spikes/android_spike/tool/signing_smoke.sh \
  spikes/android_spike/fixtures/patch-manifest.json \
  work/android-spike/patched/lib/arm64-v8a/libapp.so
```

## Android external-AOT spike (next active experiment)

The experiment builds the same app twice (`BASELINE`, then `PATCHED`), extracts the second APK's `libapp.so`, signs a manifest offline, atomically installs it under the app's private files directory, and starts a custom engine with:

```text
--aot-shared-library-name=/data/user/0/dev.hotfixruntime.android_spike/files/hotfix/active/libapp.so
```

Acceptance is deliberately strict:

1. Valid, exactly matching manifest + signature + SHA-256 displays `PATCHED` after a cold start.
2. Missing network/disk state continues with the bundled `BASELINE`.
3. Corrupt payload, invalid signature, wrong app/platform/ABI/release/Flutter/Dart/Engine/flavor/channel/build digest never reaches `dlopen` and continues with last-known-good or bundled baseline.
4. A forced crash before the launch-success checkpoint increments the boot attempt, blacklists the patch at the threshold, and restores last-known-good on the next launch.
5. Every command, device ABI, engine revision, manifest digest, selection decision, and rollback result is captured as test evidence.

See [ARCHITECTURE.md](ARCHITECTURE.md), [PLAN.md](PLAN.md), [COMPATIBILITY.md](COMPATIBILITY.md), and [SECURITY.md](SECURITY.md).

## Explicit non-goals for now

- No dashboard, database, multi-tenant service, plugin abstraction, or custom CDN protocol.
- No claim that Android, OHOS, or iOS is supported before its real-device gate passes.
- No copying of unavailable Shorebird sources or inference about unpublished Shiply internals.
