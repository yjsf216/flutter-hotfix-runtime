import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../patch_store.dart';

void check(bool value, [String message = 'patch store check failed']) {
  if (!value) throw StateError(message);
}

void makeOversized(File file, int maximumBytes) {
  final sink = file.openSync(mode: FileMode.writeOnly);
  try {
    // A sparse fixture rejects huge logical files without allocating their data.
    sink.truncateSync(maximumBytes + 1);
  } finally {
    sink.closeSync();
  }
}

void main() {
  final root = Directory.systemTemp.createTempSync('patch-store-check-');
  try {
    final storeRoot = Directory('${root.path}/basic');
    final store = PatchStore(storeRoot);
    final p1 = Uint8List.fromList(utf8.encode('patch-one'));
    final p2 = Uint8List.fromList(utf8.encode('patch-two'));
    final p3 = Uint8List.fromList(utf8.encode('patch-three'));
    final digest1 = sha256.convert(p1).toString();
    final digest2 = sha256.convert(p2).toString();
    final digest3 = sha256.convert(p3).toString();
    for (final id in ['', '../escape', 'bundled', '.', 'a/b', 'p1\n']) {
      check(!store.install(id, p1, digest1), 'invalid install ID: $id');
      check(store.readVerified(id) == null, 'invalid read ID: $id');
      check(!store.markHealthy(id), 'invalid healthy ID: $id');
      check(!store.withdraw(id), 'invalid withdrawal ID: $id');
    }
    check(!store.install('p1', p1, digest2));

    check(store.install('p1', p1, digest1));
    check(!store.markHealthy('p1'), 'health requires a pending boot');
    check(store.beginBoot() == 'p1');
    check(store.markHealthy('p1'));
    check(!store.install('p1', p2, digest2), 'an ID cannot replace LKG bytes');
    check(sha256.convert(store.readVerified('p1')!).toString() == digest1);

    check(store.install('p2', p2, digest2));
    check(store.beginBoot() == 'p2');
    check(store.beginBoot() == 'p2');
    check(store.install('p2', p2, digest2), 'same digest is idempotent');
    check(store.beginBoot() == 'p1');
    check(
      !store.install('p2', p2, digest2),
      'reinstall cannot clear blacklist',
    );
    check(!store.install('p2', p3, digest3));
    check(store.readVerified('p2') == null, 'blacklisted bytes cannot be read');
    check(!store.markHealthy('p2'));
    check(store.markHealthy('p1'));

    check(store.install('p3', p3, digest3));
    final p3File = File('${storeRoot.path}/versions/p3.ir');
    p3File.writeAsStringSync('disk-tamper');
    check(store.readVerified('p3') == null);
    check(store.beginBoot() == 'p1');
    check(store.markHealthy('p1'));
    check(
      store.install('p3', p3, digest3),
      'same digest can repair disk damage',
    );
    final stableBytes = store.readVerified('p3')!;
    p3File.writeAsStringSync('later-tamper');
    check(sha256.convert(stableBytes).toString() == digest3);
    p3File.deleteSync();
    Link(p3File.path).createSync('${storeRoot.path}/versions/p1.ir');
    check(store.readVerified('p3') == null, 'artifact symlinks are rejected');
    check(!store.install('p3', p3, digest3));
    check(store.beginBoot() == 'p1');
    check(store.markHealthy('p1'));

    check(store.withdraw('p1'));
    check(store.beginBoot() == PatchStore.bundled);
    check(store.readVerified('p1') == null);
    check(!store.install('p1', p1, digest1));

    File('${storeRoot.path}/state.json').writeAsStringSync('{corrupt');
    check(store.beginBoot() == PatchStore.bundled);
    check(!store.install('p4', p1, digest1), 'corrupt state must not throw');

    final switched = PatchStore(Directory('${root.path}/switched'));
    check(switched.install('p1', p1, digest1));
    check(switched.beginBoot() == 'p1');
    check(switched.markHealthy('p1'));
    check(switched.install('p2', p2, digest2));
    check(switched.beginBoot() == 'p2');
    check(switched.beginBoot() == 'p2');
    check(switched.install('p3', p3, digest3));
    check(
      switched.beginBoot() == 'p3',
      'failed old pending cannot replace new active',
    );
    check(
      switched.beginBoot() == 'p3',
      'failure count belongs to its pending ID',
    );
    check(switched.withdraw('unrelated'), 'withdraw an unassigned ID');
    check(switched.markHealthy('p3'), 'unrelated withdrawal preserves pending');
    check(!switched.install('p2', p2, digest2));

    final stateFile = File('${switched.root.path}/state.json');
    final goodState = stateFile.readAsStringSync();
    final invalidStates = <Map<String, Object?>>[
      {'active': '../escape'},
      {'active': 'uninstalled'},
      {'lastKnownGood': 'bundled'},
      {'pending': 42},
      {'failures': -1},
      {'failures': 1},
      {
        'blacklist': [42],
      },
      {
        'blacklist': ['../escape'],
      },
      {
        'digests': {'p3': 'bad-digest'},
      },
      {
        'digests': {'../escape': digest3},
      },
      {'unknown': true},
    ];
    for (final mutation in invalidStates) {
      final invalid = jsonDecode(goodState) as Map<String, Object?>;
      invalid.addAll(mutation);
      stateFile.writeAsStringSync(jsonEncode(invalid));
      final corrupt = PatchStore(switched.root);
      check(
        corrupt.beginBoot() == PatchStore.bundled,
        'invalid state: $mutation',
      );
      check(corrupt.readVerified('p3') == null);
      check(!corrupt.install('p4', p1, digest1));
      check(!corrupt.markHealthy('p3'));
      check(
        !corrupt.withdraw('p3'),
        'withdrawal persistence failure is reported',
      );
    }
    stateFile.writeAsStringSync(goodState);
    check(PatchStore(switched.root).beginBoot() == 'p3');

    final orphanRoot = Directory('${root.path}/orphan');
    Directory('${orphanRoot.path}/versions').createSync(recursive: true);
    File('${orphanRoot.path}/versions/p1.ir').writeAsBytesSync(p1);
    final orphan = PatchStore(orphanRoot);
    check(!orphan.install('p1', p2, digest2), 'an orphan ID remains immutable');
    final sentinel = File('${root.path}/sentinel')
      ..writeAsStringSync('untouched');
    Link('${orphanRoot.path}/versions/.p1.tmp').createSync(sentinel.path);
    Link('${orphanRoot.path}/.state.tmp').createSync(sentinel.path);
    check(orphan.install('p1', p1, digest1));
    check(orphan.beginBoot() == 'p1');
    check(
      sentinel.readAsStringSync() == 'untouched',
      'fixed temp paths are unused',
    );

    final linkedStateRoot = Directory('${root.path}/linked-state')
      ..createSync();
    Link('${linkedStateRoot.path}/state.json').createSync(stateFile.path);
    final linkedState = PatchStore(linkedStateRoot);
    check(linkedState.beginBoot() == PatchStore.bundled);
    check(!linkedState.install('p1', p1, digest1));

    final linkedVersionsRoot = Directory('${root.path}/linked-versions')
      ..createSync();
    Link(
      '${linkedVersionsRoot.path}/versions',
    ).createSync('${orphanRoot.path}/versions');
    final linkedVersions = PatchStore(linkedVersionsRoot);
    check(!linkedVersions.install('p1', p1, digest1));
    check(linkedVersions.readVerified('p1') == null);
    Link('${root.path}/linked-root').createSync(orphanRoot.path);
    final linkedRoot = PatchStore(Directory('${root.path}/linked-root'));
    check(!linkedRoot.install('p1', p1, digest1));
    check(linkedRoot.beginBoot() == PatchStore.bundled);

    final signedRoot = Directory('${root.path}/signed');
    final envelope = Uint8List.fromList(
      utf8.encode('test-only-authenticated-envelope'),
    );
    var verificationCalls = 0;
    var mutateDuringVerify = false;
    // This callback tests storage/authentication composition, not cryptography.
    // The signed-manifest check separately uses real platform-compatible keys.
    final signed = PatchStore(
      signedRoot,
      verifyManifest: (id, manifest, bytes) {
        verificationCalls++;
        final valid =
            id == 'p1' &&
            utf8.decode(manifest) == utf8.decode(envelope) &&
            sha256.convert(bytes).toString() == digest1;
        if (valid && mutateDuringVerify) {
          File('${signedRoot.path}/versions/p1.ir').writeAsBytesSync(p2);
        }
        return valid;
      },
    );
    check(
      !signed.install('p1', p1, digest1),
      'signed store requires an envelope',
    );
    check(!signed.install('p1', p1, digest1, manifest: p2));
    check(signed.install('p1', p1, digest1, manifest: envelope));
    check(signed.beginBoot() == 'p1');
    final beforeRead = verificationCalls;
    mutateDuringVerify = true;
    final verified = signed.readVerified('p1');
    mutateDuringVerify = false;
    check(verificationCalls == beforeRead + 1, 'read must reauthenticate');
    check(
      verified != null && sha256.convert(verified).toString() == digest1,
      'path replacement after verification must not change returned bytes',
    );
    check(!signed.markHealthy('p1'), 'health cannot commit a changed artifact');
    final signedStateFile = File('${signedRoot.path}/state.json');
    final forged = jsonDecode(signedStateFile.readAsStringSync()) as Map;
    (forged['digests'] as Map)['p1'] = digest2;
    signedStateFile.writeAsStringSync(jsonEncode(forged));
    check(
      signed.readVerified('p1') == null,
      'forged state digest cannot replace signature',
    );
    check(signed.beginBoot() == PatchStore.bundled);
    (forged['digests'] as Map)['p1'] = digest1;
    signedStateFile.writeAsStringSync(jsonEncode(forged));
    check(signed.install('p1', p1, digest1, manifest: envelope));
    File('${signedRoot.path}/versions/p1.manifest.json').writeAsBytesSync(p2);
    check(
      signed.readVerified('p1') == null,
      'stored envelope must reauthenticate',
    );
    check(signed.install('p1', p1, digest1, manifest: envelope));
    File('${signedRoot.path}/versions/p1.manifest.json').deleteSync();
    check(signed.readVerified('p1') == null, 'missing envelope cannot load');

    final boundedRoot = Directory('${root.path}/bounded');
    var boundedVerificationCalls = 0;
    final bounded = PatchStore(
      boundedRoot,
      verifyManifest: (id, manifest, bytes) {
        boundedVerificationCalls++;
        return utf8.decode(manifest) == utf8.decode(envelope) &&
            sha256.convert(bytes).toString() ==
                {'p1': digest1, 'p2': digest2, 'p3': digest1}[id];
      },
    );
    check(bounded.install('p1', p1, digest1, manifest: envelope));
    check(bounded.beginBoot() == 'p1');
    check(bounded.markHealthy('p1'));
    final oversizedManifest = Uint8List(PatchStore.maxManifestBytes + 1);
    final beforeOversizedInstall = boundedVerificationCalls;
    check(!bounded.install('p2', p2, digest2, manifest: oversizedManifest));
    final oversizedArtifact = Uint8List(PatchStore.maxArtifactBytes + 1);
    check(
      !bounded.install(
        'p2',
        oversizedArtifact,
        sha256.convert(oversizedArtifact).toString(),
        manifest: envelope,
      ),
    );
    check(
      boundedVerificationCalls == beforeOversizedInstall,
      'oversized install must fail before invoking verification',
    );
    check(!File('${boundedRoot.path}/versions/p2.ir').existsSync());
    check(bounded.install('p2', p2, digest2, manifest: envelope));
    final oversizedArtifactFile = File('${boundedRoot.path}/versions/p2.ir');
    makeOversized(oversizedArtifactFile, PatchStore.maxArtifactBytes);
    final beforeOversizedRead = boundedVerificationCalls;
    check(bounded.readVerified('p2') == null);
    check(boundedVerificationCalls == beforeOversizedRead);
    check(bounded.beginBoot() == 'p1', 'oversized artifact falls back to LKG');
    check(bounded.markHealthy('p1'));
    check(bounded.install('p2', p2, digest2, manifest: envelope));
    makeOversized(
      File('${boundedRoot.path}/versions/p2.manifest.json'),
      PatchStore.maxManifestBytes,
    );
    final beforeOversizedEnvelope = boundedVerificationCalls;
    check(bounded.readVerified('p2') == null);
    check(boundedVerificationCalls == beforeOversizedEnvelope);
    check(bounded.beginBoot() == 'p1', 'oversized manifest falls back to LKG');
    check(bounded.markHealthy('p1'));

    final boundedStateFile = File('${boundedRoot.path}/state.json');
    final validBoundedState = boundedStateFile.readAsStringSync();
    final nearFullState = jsonDecode(validBoundedState) as Map;
    final stateBaseBytes = utf8.encode(jsonEncode(nearFullState)).length;
    final blacklist = nearFullState['blacklist'] as List;
    final entries = (PatchStore.maxStateBytes - stateBaseBytes) ~/ 131;
    blacklist.addAll(
      List.generate(entries, (i) => 'b${i.toString().padLeft(127, '0')}'),
    );
    final remaining =
        PatchStore.maxStateBytes -
        utf8.encode(jsonEncode(nearFullState)).length;
    if (remaining >= 4) blacklist.add('x' * (remaining - 3));
    final fullStateBytes = utf8.encode(jsonEncode(nearFullState));
    check(
      fullStateBytes.length <= PatchStore.maxStateBytes &&
          fullStateBytes.length > PatchStore.maxStateBytes - 4,
    );
    boundedStateFile.writeAsBytesSync(fullStateBytes);
    check(
      !bounded.withdraw('w' * 128),
      'state write must enforce the size cap',
    );
    check(
      boundedStateFile.lengthSync() == fullStateBytes.length,
      'oversized replacement must leave the previous state intact',
    );
    check(
      bounded.readVerified('p1') != null,
      'a state at the byte limit remains readable',
    );
    check(!bounded.install('p3', p1, digest1, manifest: envelope));
    check(
      sha256.convert(boundedStateFile.readAsBytesSync()).toString() ==
          sha256.convert(fullStateBytes).toString(),
      'an install exceeding the state cap leaves prior state intact',
    );
    makeOversized(boundedStateFile, PatchStore.maxStateBytes);
    check(bounded.beginBoot() == PatchStore.bundled);
    check(bounded.readVerified('p1') == null);
    check(!bounded.install('p1', p1, digest1, manifest: envelope));
    check(
      boundedStateFile.lengthSync() == PatchStore.maxStateBytes + 1,
      'oversized state is not overwritten with reset failure evidence',
    );

    final oversizedOrphanRoot = Directory('${root.path}/oversized-orphan');
    Directory(
      '${oversizedOrphanRoot.path}/versions',
    ).createSync(recursive: true);
    final oversizedOrphan = File('${oversizedOrphanRoot.path}/versions/p1.ir');
    makeOversized(oversizedOrphan, PatchStore.maxArtifactBytes);
    check(!PatchStore(oversizedOrphanRoot).install('p1', p1, digest1));
    check(oversizedOrphan.lengthSync() == PatchStore.maxArtifactBytes + 1);

    print(
      'PASS: immutable IDs, pending-specific failure counts, LKG and persistent blacklist',
    );
    print(
      'PASS: strict state/paths, symlinks, orphan adoption and unique atomic files',
    );
    print(
      'PASS: same-buffer verification and signed-envelope revalidation at every load',
    );
    print(
      'PASS: bounded artifact/manifest/state I/O, sparse oversize fallback and capped writes',
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}
