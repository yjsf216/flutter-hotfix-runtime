import 'dart:io';
import 'dart:typed_data';

import 'patch_store.dart';
import 'native_store_io.dart';
import 'signed_manifest.dart';

/// A completed load operation, not an automatically healthy/committed boot.
final class LoadedPatch<T> {
  LoadedPatch._(this._owner, this._attempt, this.value);

  final SignedPatchLoader _owner;
  final PatchBootAttempt _attempt;
  String get patchId => _attempt.patchId;
  final T value;
}

final class SignedPatchLoader {
  SignedPatchLoader({
    required Directory root,
    required this.verifier,
    NativeStoreIo? nativeIo,
  }) {
    store = PatchStore(
      root,
      verifyManifest: _verifyStored,
      verifyHealthyManifest: _verifyHealthy,
      nativeIo: nativeIo,
    );
  }

  final SignedManifestVerifier verifier;
  late final PatchStore store;
  var _loadGeneration = 0;
  void close() {
    _loadGeneration++;
    store.close();
  }

  bool _verifyStored(String patchId, Uint8List envelope, Uint8List artifact) {
    final verified = verifier.verify(envelope);
    return verified != null &&
        verified.patchId == patchId &&
        verified.matchesArtifact(artifact);
  }

  bool _verifyHealthy(String patchId, Uint8List envelope, Uint8List artifact) {
    final verified = verifier.verify(envelope, allowExpiredHealthy: true);
    return verified != null &&
        verified.patchId == patchId &&
        verified.matchesArtifact(artifact);
  }

  bool stage(String manifestPath, String modulePath) {
    try {
      final envelope = _readSource(manifestPath, maxManifestBytes);
      if (envelope == null) return false;
      final manifest = verifier.verify(envelope);
      if (manifest == null || !eligible(manifest)) return false;
      final artifact = _readSource(modulePath, manifest.artifactSize);
      return artifact != null && stageBytes(envelope, artifact);
    } on Object {
      return false;
    }
  }

  /// Accept only fully downloaded authenticated bytes; native store commits
  /// them atomically. Installing does not activate a module in this process.
  bool stageBytes(Uint8List envelope, Uint8List artifact) {
    final manifest = verifier.verify(envelope);
    return manifest != null &&
        eligible(manifest) &&
        manifest.matchesArtifact(artifact) &&
        store.install(
          manifest.patchId,
          artifact,
          manifest.artifactSha256,
          manifest: envelope,
        );
  }

  bool eligible(VerifiedManifest manifest) {
    if (manifest.revoked) return false;
    if (manifest.rolloutPercent == 100) return true;
    if (manifest.rolloutPercent == 0) return false;
    final bucket = store.rolloutBucket(manifest.baselineId, manifest.patchId);
    return bucket != null && bucket < manifest.rolloutPercent;
  }

  bool withdrawSigned(Uint8List envelope) {
    // Revocation is permanent for this immutable patch ID; replay cannot undo it.
    final manifest = verifier.verify(
      envelope,
      allowRevocation: true,
      allowExpiredHealthy: true,
    );
    return manifest != null &&
        manifest.revoked &&
        store.withdraw(manifest.patchId);
  }

  Uint8List? _readSource(String path, int limit) => store.nativeIo == null
      ? _readBounded(path, limit)
      : store.nativeIo!.readSource(path, limit);

  /// The callback receives the exact bytes rehashed and reauthenticated by the
  /// store. It may load, validate and activate the module. A failed callback
  /// undoes its dispatch changes through [restoreBaseline], durably rejects the
  /// failed candidate, then tries a reauthenticated distinct LKG at most once.
  /// Only unexplained process death remains pending for the next startup.
  Future<LoadedPatch<T>?> load<T>(
    Future<T> Function(Uint8List bytes) loadAndValidate, {
    required void Function() restoreBaseline,
  }) async {
    final generation = ++_loadGeneration;
    var attempt = store.beginBootAttempt();
    final incomplete = store.previousIncompleteBoot;
    if (incomplete != null)
      store.enqueueReport(verifier.baselineId, incomplete, 'startup_failed');
    if (attempt == null) {
      restoreBaseline();
      return null;
    }
    for (var tried = 0; attempt != null && tried < 2; tried++) {
      try {
        final bytes = store.readVerified(attempt.patchId);
        if (bytes == null)
          throw StateError('selected patch failed revalidation');
        final value = await loadAndValidate(bytes);
        return LoadedPatch._(this, attempt, value);
      } on Object {
        // An older callback must not clear a later load's active dispatch.
        if (generation != _loadGeneration) return null;
        store.enqueueReport(
          verifier.baselineId,
          attempt.patchId,
          'startup_failed',
        );
        final rejection = store.rejectBootAndBeginFallback(
          attempt,
          allowFallback: tried == 0,
        );
        if (rejection?.superseded == true) return null;
        // Restore outside the protected callback. Broken rollback propagates;
        // failed rejection persistence returns bundled without loading LKG.
        restoreBaseline();
        attempt = rejection?.fallback;
      }
    }
    return null;
  }

  /// Call after activation and the application's health checkpoint, not merely
  /// because a bytecode entrypoint returned. Foreign loader results are rejected.
  bool markHealthy<T>(LoadedPatch<T> patch) =>
      identical(patch._owner, this) && store.markBootHealthy(patch._attempt);
}

Uint8List? _readBounded(String path, int limit) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    return null;
  }
  final file = File(path).openSync();
  try {
    if (file.lengthSync() > limit) return null;
    final bytes = file.readSync(limit + 1);
    return bytes.length <= limit ? bytes : null;
  } finally {
    file.closeSync();
  }
}
