# Actual host Flutter Engine AOT/DBC3 evidence

The real software-surface Engine gate passed. This is **not** Android, iOS or
OHOS execution evidence, and no connected device or simulator was used.

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
