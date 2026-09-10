# Actual host Flutter Engine AOT/DBC3 evidence

The real software-surface Engine gate passed. This host gate used no device or
simulator. Subsequent authorized Android execution is documented separately in
[Android device evidence](../spikes/android_spike/DEVICE_EVIDENCE.md); iOS/OHOS
execution remains unverified.

Run from the repository root:

```sh
sh engine/run_host_ddm.sh
```

Latest verified artifacts: `work/engine-ddm-check.bJV6j5/engine-evidence.json`.
The Engine build log is `work/engine-host-build.DzhUvj`; it ends with a successful
shared-library link, framework copy and symlink generation. Source/toolchain
pins and applied build patches are recorded in [README.md](README.md).

## What executed

`FlutterEngineGetProcAddresses` loaded the actual arm64 Engine library;
`RunsAOTCompiledDartCode` was required. Four fresh processes used the same AOT ELF.
The ordinary Dart `HotfixGreeting.build` patch was generated as DBC3 and loaded
through P-256 verification and the native transactional store. The patch calls
the unchanged baseline `label` helper and constructs the baseline Framework's
`Text`; it does not ship another Framework copy.

The Dart fixture defers the first frame during asynchronous patch loading and
inspects the mounted Text child after `endOfFrame`, not a second manual `build`.
It asserts that no frame escaped the gate, allows the validated Widget frame,
and waits for `waitUntilFirstFrameRasterized` before committing health. Thus an
empty frame during bootstrap cannot satisfy that checkpoint. The runner also
requires both the Dart assertion result and
a real 320×240 software surface callback before a successful shutdown.

| Case | Mounted Text assertion | Software frame FNV-64 | Result |
|---|---|---|---|
| Baseline | `Flutter: baseline` | `e1557a0723fc12e5` | PASS |
| P-256 signed patch | `Flutter: patched` | `fa8822fc5ec54111` | PASS |
| Forged signature envelope | `Flutter: baseline` | `e1557a0723fc12e5` | PASS |
| Valid signature, wrong baseline ID | `Flutter: baseline` | `e1557a0723fc12e5` | PASS |

The frame fingerprint is only a diagnostic observation, not a cryptographic
check, a portable golden image or an independent identification of glyph pixels.

## Durable state and fingerprints

The signed case persisted `active=p1`, `lastKnownGood=p1`, `pending=null`,
`pendingAttempt=null`, zero failures, and the authenticated patch digest.
Both rejected cases retained null active/LKG/pending state, an empty digest map
and no persisted version artifact. The script verifies this after process exit.

```text
Engine SHA-256:
2f611ae459c51347bff8fc93637cfe152890df34522e2c36117637de5c2990d9
Baseline AOT ELF SHA-256:
2dfa543bff678fc1858c9a207c5a98a58461b3041be6e1489d968376100f370c
DBC3 patch SHA-256:
60a92c009c1e15a35de637e59d37132c6017e83a2f0cd5894587a61f4185903d
Frozen baseline ID:
305ad4359673150209d558aab769c686c00a7eaeb9277cae3a004c129a5a4668
```

Each run embeds a fresh test public key, so snapshot, baseline and patch identities
can change on rerun. Test private keys remain in the ignored work directory and
are not production keys.

Remaining gates include mobile Engine linking/packaging, actual target execution,
iOS Metal tooling, broader Engine-level semantic/failure coverage, performance,
durability and policy review. Passing this finite matrix does not complete the
three-platform Runtime goal.

## Android development APK: packaging gate passed

`spikes/android_spike/build/prebuilt-app/outputs/apk/release/app-release.apk`
was built offline using the explicit `hotfix.prebuilt` Gradle mode. This mode
does not load Flutter's Gradle plugins or run `flutter assemble`, so it does not
regenerate the frozen patch-point baseline. It uses the pinned Java embedding
`1.0.0-42d3d75a56efe1a2e9902f52dc8006099c45d937` and builds the native store from
the existing CMake source. Signing is the development/debug key, not production.

Build and verification logs: `work/luna-prebuilt-assembleRelease.log` and
`work/luna-prebuilt-verify.log`. Staged inputs are retained at
`work/luna-prebuilt-stage.zqORes`.

- APK v2 signature verification passed.
- Exactly three native libraries are packaged, all under `lib/arm64-v8a`.
- Engine and baseline AOT payloads are byte-identical to their staged inputs.
- All seven `psio_*` exports are present in the native store.
- `zipalign -c -P 16 -v 4` passed for the whole APK. Engine/AOT LOAD segments
  have 64 KiB alignment; native-store LOAD segments have 16 KiB alignment.

```text
APK SHA-256:
c344add3ed61503f5dcf65e8530ddd1f679f61bd11adc23e374f8b37bb8ab3e1
Packaged libflutter.so SHA-256:
7a4e2d4e156c5961d7c3a708487419fba09839e2d7822be9d5afecc60993bc99
Packaged libapp.so SHA-256:
b1a40f3f889feda8e6b7afc603f9ffe80c357a7eed04ac0adf4d45788262c15e
```

The baseline and signed patch inputs come from `work/android-release-check.qft7KT`.
The APK packages the baseline/runtime, not an automatically applied downloaded
patch. That original packaging-only APK was not installed or launched. A later
development APK connects startup and passes the authorized Android device matrix
linked above; remote patch acquisition remains unverified.
