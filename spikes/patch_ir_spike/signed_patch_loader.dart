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
    store = PatchStore(root, verifyManifest: _verifyStored, nativeIo: nativeIo);
  }

  final SignedManifestVerifier verifier;
  late final PatchStore store;
  void close() => store.close();

  bool _verifyStored(String patchId, Uint8List envelope, Uint8List artifact) {
    final verified = verifier.verify(envelope);
    // ponytail: only full rollout is implemented; partial selection needs a
    // persistent privacy-preserving install bucket shared across restarts.
    return verified != null &&
        verified.rolloutPercent == 100 &&
        verified.patchId == patchId &&
        verified.matchesArtifact(artifact);
  }

  bool stage(String manifestPath, String modulePath) {
    try {
      final envelope = _readSource(manifestPath, maxManifestBytes);
      if (envelope == null) return false;
      final manifest = verifier.verify(envelope);
      if (manifest == null || manifest.rolloutPercent != 100) return false;
      final artifact = _readSource(modulePath, manifest.artifactSize);
      return artifact != null &&
          store.install(
            manifest.patchId,
            artifact,
            manifest.artifactSha256,
            manifest: envelope,
          );
    } on Object {
      return false;
    }
  }

  Uint8List? _readSource(String path, int limit) => store.nativeIo == null
      ? _readBounded(path, limit)
      : store.nativeIo!.readSource(path, limit);

  /// The callback receives the exact bytes rehashed and reauthenticated by the
  /// store. It may load, validate and activate the module. A failed callback
  /// must undo dispatch changes through [restoreBaseline] before returning null.
  /// Pending-boot failure evidence survives until the next startup.
  Future<LoadedPatch<T>?> load<T>(
    Future<T> Function(Uint8List bytes) loadAndValidate, {
    required void Function() restoreBaseline,
  }) async {
    try {
      final attempt = store.beginBootAttempt();
      final bytes = attempt == null
          ? null
          : store.readVerified(attempt.patchId);
      if (attempt != null && bytes != null) {
        final value = await loadAndValidate(bytes);
        return LoadedPatch._(this, attempt, value);
      }
    } on Object {
      // Restore outside the catch: a broken rollback must never claim success.
    }
    restoreBaseline();
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
