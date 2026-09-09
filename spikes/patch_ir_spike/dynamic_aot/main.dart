import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dynamic_modules/dynamic_modules.dart';

import '../patch_store.dart';
import '../signed_manifest.dart';
import '../signed_patch_loader.dart';
import 'release_identity.dart';
import 'runtime_api.dart';

// Test build injects only the public key; private key stays with the offline
// OpenSSL signer. Shipping builds embed their release-managed public-key set.
final manifestVerifier = SignedManifestVerifier(
  baselineId: baselineId,
  releaseIdentity: releaseIdentity,
  publicKeys: {
    'spike-p256-1': base64.decode(
      const String.fromEnvironment('HOTFIX_TEST_PUBLIC_KEY'),
    ),
  },
);

Future<void> main() async {
  final pricing = Pricing();
  final storeRoot = Directory('patch-store');
  final loader = SignedPatchLoader(root: storeRoot, verifier: manifestVerifier);
  final store = loader.store;
  if (pricing.quote(3) != 4) throw StateError('baseline dispatch failed');

  var rejected = false;
  try {
    installPatches(<String, PatchBody>{
      Pricing.quoteId: (_) => 99,
      'unknown': (_) => 100,
    });
  } on StateError {
    rejected = true;
  }
  if (!rejected) throw StateError('invalid table was accepted');
  if (pricing.quote(3) != 4) {
    throw StateError('invalid table was partially installed');
  }

  if (loader.stage('bad-manifest.json', 'modules/patch.dart.bytecode')) {
    throw StateError('mismatched manifest was accepted');
  }
  if (loader.stage('manifest.json', 'modules/tampered.bytecode')) {
    throw StateError('tampered bytecode was accepted');
  }
  final unsignedTamper =
      jsonDecode(File('manifest.json').readAsStringSync())
          as Map<String, Object?>;
  (unsignedTamper['manifest'] as Map)['identity'] = {
    ...releaseIdentity,
    'channel': 'attacker-channel',
  };
  File(
    'bad-identity.json',
  ).writeAsBytesSync(canonicalManifestBytes(unsignedTamper));
  if (loader.stage('bad-identity.json', 'modules/patch.dart.bytecode')) {
    throw StateError('forged identity was accepted');
  }
  if (pricing.quote(3) != 4) throw StateError('failed patch changed baseline');
  if (!loader.stage('manifest.json', 'modules/patch.dart.bytecode')) {
    throw StateError('valid patch was rejected');
  }

  File('${storeRoot.path}/versions/p1.ir').writeAsStringSync('disk-tamper');
  if (store.beginBoot() != PatchStore.bundled || pricing.quote(3) != 4) {
    throw StateError('stored tamper did not fall back to baseline');
  }
  if (!loader.stage('manifest.json', 'modules/patch.dart.bytecode')) {
    throw StateError('valid patch could not be restaged');
  }

  // Two async loads of the same signed patch must retain distinct health
  // capabilities, whether they share a loader or have independent owners.
  for (final sameOwner in [false, true]) {
    final overlapRoot = Directory('overlapping-loads-$sameOwner');
    final first = SignedPatchLoader(
      root: overlapRoot,
      verifier: manifestVerifier,
    );
    final second = sameOwner
        ? first
        : SignedPatchLoader(root: overlapRoot, verifier: manifestVerifier);
    if (!first.stage('manifest.json', 'modules/patch.dart.bytecode')) {
      throw StateError('overlap fixture install failed');
    }
    final entered = Completer<void>();
    final resume = Completer<void>();
    final waiting = first.load((bytes) async {
      entered.complete();
      await resume.future;
      return bytes.length;
    }, restoreBaseline: () {});
    await entered.future;
    final newest = await second.load(
      (bytes) async => bytes.length,
      restoreBaseline: () {},
    );
    resume.complete();
    final stale = await waiting;
    if (newest == null || stale == null)
      throw StateError('overlap load failed');
    final state = File('${overlapRoot.path}/state.json');
    final beforeLateAck = state.readAsStringSync();
    if (first.markHealthy(stale) || state.readAsStringSync() != beforeLateAck) {
      throw StateError('stale loaded result cleared newer pending/failures');
    }
    if (!second.markHealthy(newest))
      throw StateError('newest boot health failed');
  }

  // Both local state and the stored manifest are untrusted after a restart.
  for (final alsoForgeManifest in [false, true]) {
    final attackedRoot = Directory('attacked-store-$alsoForgeManifest');
    final beforeRestart = SignedPatchLoader(
      root: attackedRoot,
      verifier: manifestVerifier,
    );
    if (!beforeRestart.stage('manifest.json', 'modules/patch.dart.bytecode')) {
      throw StateError('attack fixture install failed');
    }
    final attackedArtifact = File('${attackedRoot.path}/versions/p1.ir');
    final changedBytes = attackedArtifact.readAsBytesSync()..[0] ^= 1;
    attackedArtifact.writeAsBytesSync(changedBytes);
    final changedHash = sha256.convert(changedBytes).toString();
    final stateFile = File('${attackedRoot.path}/state.json');
    final forgedState = jsonDecode(stateFile.readAsStringSync()) as Map;
    (forgedState['digests'] as Map)['p1'] = changedHash;
    stateFile.writeAsStringSync(jsonEncode(forgedState));
    if (alsoForgeManifest) {
      final manifestFile = File(
        '${attackedRoot.path}/versions/p1.manifest.json',
      );
      final forged =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
      (forged['manifest'] as Map)['artifactSha256'] = changedHash;
      manifestFile.writeAsBytesSync(canonicalManifestBytes(forged));
    }
    final restarted = SignedPatchLoader(
      root: attackedRoot,
      verifier: manifestVerifier,
    );
    if (restarted.store.beginBoot() != PatchStore.bundled ||
        restarted.store.readVerified('p1') != null) {
      throw StateError('artifact/state/manifest forgery survived restart');
    }
  }
  void restoreBaseline() => installPatches(<String, PatchBody>{});
  final failedRoot = Directory('failed-activation-store');
  final failedLoader = SignedPatchLoader(
    root: failedRoot,
    verifier: manifestVerifier,
  );
  if (!failedLoader.stage('manifest.json', 'modules/patch.dart.bytecode')) {
    throw StateError('activation failure fixture install failed');
  }
  final failed = await failedLoader.load<Object?>((bytes) async {
    // Failure injection after authenticated bytes reach application activation.
    // Actual DBC3 is loaded once below; reloading one module URI is unsupported.
    installPatches(<String, PatchBody>{Pricing.quoteId: (_) => 99});
    throw StateError('application rejected initialized patch');
  }, restoreBaseline: restoreBaseline);
  final failedState =
      jsonDecode(File('${failedRoot.path}/state.json').readAsStringSync())
          as Map;
  if (failed != null ||
      pricing.quote(3) != 4 ||
      failedState['pending'] != 'p1' ||
      failedState['lastKnownGood'] != null) {
    throw StateError(
      'failed activation did not restore baseline and preserve pending evidence',
    );
  }
  final loaded = await loader.load((bytes) async {
    final module = await loadModuleFromBytes(bytes);
    installPatches(module);
    if (pricing.quote(3) != 37) throw StateError('patch activation failed');
    return module;
  }, restoreBaseline: restoreBaseline);
  if (loaded == null || loaded.patchId != 'p1') {
    throw StateError('signed stored patch was not loaded');
  }
  if (failedLoader.markHealthy(loaded)) {
    throw StateError('foreign loader acknowledged another boot');
  }
  final beforeHealth =
      jsonDecode(File('${storeRoot.path}/state.json').readAsStringSync())
          as Map;
  if (beforeHealth['lastKnownGood'] != null ||
      beforeHealth['pending'] != 'p1') {
    throw StateError('module load prematurely marked boot healthy');
  }

  for (var i = 0; i < 20000; i++) {
    if (pricing.quote(3) != 37) throw StateError('patched dispatch failed');
  }
  var caught = false;
  try {
    pricing.fail();
  } on StateError catch (error) {
    caught = error.message == 'interpreted failure';
  }
  if (!caught) throw StateError('interpreted exception did not cross AOT');
  if (await pricing.asyncQuote(3) != 37) {
    throw StateError('interpreted async did not cross AOT');
  }
  final loadedPatches = activePatches();
  final isolateResults = await Future.wait(
    List.generate(
      16,
      (_) => Isolate.run(() async {
        final isolatedPricing = Pricing();
        if (isolatedPricing.quote(3) != 4) return false;
        installPatches(loadedPatches);
        for (var i = 0; i < 1000; i++) {
          if (isolatedPricing.quote(3) != 37) return false;
        }
        for (var i = 0; i < 10; i++) {
          if (await isolatedPricing.asyncQuote(3) != 37) return false;
        }
        try {
          isolatedPricing.fail();
          return false;
        } on StateError catch (error) {
          return error.message == 'interpreted failure';
        }
      }),
    ),
  );
  if (isolateResults.any((passed) => !passed)) {
    throw StateError('isolate-local patch churn failed');
  }
  if (!loader.markHealthy(loaded)) throw StateError('health commit failed');
  print(
    'PASS: P-256 signed store rejects restart forgery + GC/exception/async/isolate AOT <-> interpreted closures',
  );
}
