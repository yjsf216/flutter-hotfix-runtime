import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'native_store_io.dart';

/// A process-local capability for one durable pending-boot attempt.
final class PatchBootAttempt {
  PatchBootAttempt._(this._owner, this.patchId, this._token);

  final PatchStore _owner;
  final String patchId;
  final String _token;
}

class PatchStore {
  PatchStore(this.root, {this.verifyManifest, this.nativeIo}) {
    if (nativeIo != null &&
        nativeIo!.root.absolute.path != root.absolute.path) {
      throw ArgumentError('native store root does not match');
    }
  }

  static const bundled = 'bundled';
  static const failureLimit = 2;
  static const maxArtifactBytes = 64 * 1024 * 1024;
  static const maxManifestBytes = 16 * 1024;
  static const maxStateBytes = 1024 * 1024;
  final Directory root;
  final NativeStoreIo? nativeIo;
  final bool Function(String patchId, Uint8List envelope, Uint8List artifact)?
  verifyManifest;
  final _withdrawn = <String>{};
  PatchBootAttempt? _ownedBoot;

  static bool _isPatchId(Object? value) =>
      value is String &&
      value != bundled &&
      RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$').hasMatch(value);

  static bool _isDigest(Object? value) =>
      value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  T _transaction<T>(T failure, T Function() action) {
    try {
      return nativeIo == null ? action() : nativeIo!.transaction(action);
    } on Object {
      return failure;
    }
  }

  bool install(
    String patchId,
    Uint8List ir,
    String expectedSha256, {
    Uint8List? manifest,
  }) => _transaction(
    false,
    () => _install(patchId, ir, expectedSha256, manifest: manifest),
  );
  // Synchronous-oracle compatibility only: markHealthy(id) confirms this
  // owner's latest attempt. Asynchronous/production callers must retain the
  // exact beginBootAttempt() result and pass it to markBootHealthy(), since
  // patch IDs cannot distinguish overlapping attempts on the same owner.
  String beginBoot() => beginBootAttempt()?.patchId ?? bundled;
  PatchBootAttempt? beginBootAttempt() {
    _ownedBoot = null;
    return _transaction(null, _beginBootAttempt);
  }

  Uint8List? readVerified(String patchId) =>
      _transaction(null, () => _readVerified(patchId));
  bool markHealthy(String patchId) {
    final attempt = _ownedBoot;
    return attempt != null &&
        attempt.patchId == patchId &&
        markBootHealthy(attempt);
  }

  bool markBootHealthy(PatchBootAttempt attempt) =>
      _transaction(false, () => _markBootHealthy(attempt));
  bool withdraw(String patchId) =>
      _transaction(false, () => _withdraw(patchId));
  void close() {
    _ownedBoot = null;
    nativeIo?.close();
  }

  bool _install(
    String patchId,
    Uint8List ir,
    String expectedSha256, {
    Uint8List? manifest,
  }) {
    if (!_isPatchId(patchId) ||
        !_isDigest(expectedSha256) ||
        ir.length > maxArtifactBytes ||
        (manifest != null && manifest.length > maxManifestBytes) ||
        sha256.convert(ir).toString() != expectedSha256) {
      return false;
    }
    try {
      final verify = verifyManifest;
      if (verify != null &&
          (manifest == null || !verify(patchId, manifest, ir))) {
        return false;
      }
      if (verify == null && manifest != null) return false;
      final state = _read();
      if (_denied(patchId, state)) return false;
      final digests = state['digests'] as Map<String, Object?>;
      final existing = digests[patchId];
      // IDs are immutable, including the last-known-good and failed versions.
      if (existing != null && existing != expectedSha256) return false;
      final target = _artifact(patchId);
      final current = existing == null
          ? _readOptional(target, maxArtifactBytes)
          : null;
      if (existing != null && nativeIo == null) {
        final kind = FileSystemEntity.typeSync(target.path, followLinks: false);
        if (kind != FileSystemEntityType.file &&
            kind != FileSystemEntityType.notFound)
          return false;
      }
      // A crash may leave an artifact before the state commit. Only adopt an
      // identical orphan; a different artifact must receive a new patch ID.
      if (existing == null &&
          current != null &&
          sha256.convert(current).toString() != expectedSha256) {
        return false;
      }
      if (manifest != null) {
        _replace(_manifest(patchId), manifest, maxManifestBytes);
      }
      _replace(target, ir, maxArtifactBytes);
      state['active'] = patchId;
      digests[patchId] = expectedSha256;
      _write(state);
      return true;
    } on Object {
      return false;
    }
  }

  PatchBootAttempt? _beginBootAttempt() {
    try {
      final state = _read();
      final pending = state['pending'] as String?;
      if (pending != null) {
        final failures = (state['failures'] as int) + 1;
        state['failures'] = failures;
        if (failures >= failureLimit) {
          final blacklist = state['blacklist'] as List<Object?>;
          if (!blacklist.contains(pending)) blacklist.add(pending);
          if (state['active'] == pending) {
            state['active'] = state['lastKnownGood'];
          }
        }
      }
      final selected = _select(state);
      if (selected != pending) state['failures'] = 0;
      state['pending'] = selected == bundled ? null : selected;
      final random = Random.secure();
      final attempt = selected == bundled
          ? null
          : PatchBootAttempt._(
              this,
              selected,
              List.generate(
                16,
                (_) => random.nextInt(256),
              ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
            );
      state['pendingAttempt'] = attempt?._token;
      _write(state);
      _ownedBoot = attempt;
      return attempt;
    } on Object {
      return null;
    }
  }

  Uint8List? _readVerified(String patchId) {
    try {
      final state = _read();
      return _verifiedBytes(patchId, state);
    } on Object {
      return null;
    }
  }

  bool _markBootHealthy(PatchBootAttempt attempt) {
    try {
      if (!identical(attempt._owner, this) || !identical(attempt, _ownedBoot))
        return false;
      final state = _read();
      final patchId = attempt.patchId;
      if (state['pending'] != patchId ||
          state['pendingAttempt'] != attempt._token ||
          _verifiedBytes(patchId, state) == null) {
        return false;
      }
      state['lastKnownGood'] = patchId;
      // A downloader may have staged another candidate since this boot began.
      // Acknowledge this boot without discarding that next-startup selection.
      state['pending'] = null;
      state['pendingAttempt'] = null;
      state['failures'] = 0;
      _write(state);
      _ownedBoot = null;
      return true;
    } on Object {
      return false;
    }
  }

  bool _withdraw(String patchId) {
    if (!_isPatchId(patchId)) return false;
    // Deny in this owner even if the durable write fails; the caller receives
    // false and must retry persistence before relying on a subsequent process.
    _withdrawn.add(patchId);
    try {
      final state = _read();
      final blacklist = state['blacklist'] as List<Object?>;
      if (!blacklist.contains(patchId)) blacklist.add(patchId);
      if (state['lastKnownGood'] == patchId) state['lastKnownGood'] = null;
      if (state['active'] == patchId) state['active'] = state['lastKnownGood'];
      if (state['pending'] == patchId) {
        state['pending'] = null;
        state['pendingAttempt'] = null;
        state['failures'] = 0;
      }
      _write(state);
      return true;
    } on Object {
      return false;
    }
  }

  String _select(Map<String, Object?> state) {
    for (final candidate in [state['active'], state['lastKnownGood']]) {
      if (candidate is String && _verifiedBytes(candidate, state) != null) {
        return candidate;
      }
    }
    return bundled;
  }

  File _artifact(String patchId) {
    if (nativeIo == null) _checkDirectory(Directory('${root.path}/versions'));
    return File('${root.path}/versions/$patchId.ir');
  }

  File _manifest(String patchId) =>
      File('${root.path}/versions/$patchId.manifest.json');

  bool _denied(String patchId, Map<String, Object?> state) =>
      _withdrawn.contains(patchId) ||
      (state['blacklist'] as List<Object?>).contains(patchId);

  Uint8List? _verifiedBytes(String patchId, Map<String, Object?> state) {
    if (!_isPatchId(patchId) || _denied(patchId, state)) return null;
    final file = _artifact(patchId);
    final expected = (state['digests'] as Map<String, Object?>)[patchId];
    try {
      if (expected is! String) return null;
      final bytes = _readOptional(file, maxArtifactBytes);
      if (bytes == null) return null;
      if (sha256.convert(bytes).toString() != expected) return null;
      final verify = verifyManifest;
      if (verify != null) {
        final envelope = _readOptional(_manifest(patchId), maxManifestBytes);
        if (envelope == null || !verify(patchId, envelope, bytes)) {
          return null;
        }
      }
      // Return the exact buffer hashed here, never a second path-based read.
      return bytes;
    } on Object {
      // An unreadable candidate must not suppress a readable last-known-good.
      return null;
    }
  }

  Map<String, Object?> _read() {
    if (nativeIo == null) _checkDirectory(root);
    final file = File('${root.path}/state.json');
    final stateBytes = _readOptional(file, maxStateBytes);
    if (stateBytes == null) return _emptyState();
    final value = jsonDecode(utf8.decode(stateBytes));
    // Retain earlier store state and its failure evidence. An unowned legacy
    // token cannot acknowledge health; a new boot always mints its own token.
    if (value is Map<String, Object?> &&
        value.length == 6 &&
        !value.containsKey('pendingAttempt')) {
      value['pendingAttempt'] = value['pending'] == null ? null : '0' * 32;
    }
    if (value is! Map<String, Object?> ||
        value.length != 7 ||
        !value.keys.toSet().containsAll(_emptyState().keys) ||
        value['blacklist'] is! List<Object?> ||
        value['digests'] is! Map<String, Object?> ||
        value['failures'] is! int ||
        (value['failures'] as int) < 0) {
      throw const FormatException('invalid state');
    }
    final digests = value['digests'] as Map<String, Object?>;
    if (digests.entries.any(
          (entry) => !_isPatchId(entry.key) || !_isDigest(entry.value),
        ) ||
        (value['blacklist'] as List<Object?>).any((id) => !_isPatchId(id)) ||
        ['active', 'lastKnownGood', 'pending'].any((key) {
          final id = value[key];
          return id != null && (!_isPatchId(id) || !digests.containsKey(id));
        }) ||
        (value['pending'] == null
            ? value['failures'] != 0 || value['pendingAttempt'] != null
            : value['pendingAttempt'] is! String ||
                  !RegExp(
                    r'^[a-f0-9]{32}$',
                  ).hasMatch(value['pendingAttempt'] as String))) {
      throw const FormatException('invalid state identity');
    }
    return value;
  }

  void _write(Map<String, Object?> state) {
    _replace(
      File('${root.path}/state.json'),
      utf8.encode(jsonEncode(state)),
      maxStateBytes,
    );
  }

  Uint8List _readBounded(File file, int maximumBytes) {
    final source = file.openSync();
    try {
      final length = source.lengthSync();
      if (length > maximumBytes) {
        throw const FormatException('store file exceeds size limit');
      }
      // Bound allocation even if the file grows after the descriptor length
      // check. One extra byte detects growth without reopening its path.
      final bytes = source.readSync(length + 1);
      if (bytes.length != length) {
        throw const FormatException('store file changed during read');
      }
      return bytes;
    } finally {
      source.closeSync();
    }
  }

  String _relative(File file) {
    final prefix = '${root.absolute.path}/';
    if (!file.absolute.path.startsWith(prefix))
      throw const FormatException('path outside native store');
    return file.absolute.path.substring(prefix.length);
  }

  Uint8List? _readOptional(File file, int maximumBytes) {
    final native = nativeIo;
    if (native != null) return native.read(_relative(file), maximumBytes);
    final kind = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) return null;
    if (kind != FileSystemEntityType.file)
      throw const FormatException('invalid store file');
    return _readBounded(file, maximumBytes);
  }

  void _checkDirectory(Directory directory) {
    final kind = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (kind != FileSystemEntityType.directory &&
        kind != FileSystemEntityType.notFound) {
      throw const FormatException('invalid store directory');
    }
  }

  // ponytail: the Dart-only fallback is a single-owner oracle. Production uses
  // native transactions and directory fsync through the first branch below.
  void _replace(File target, List<int> bytes, int maximumBytes) {
    if (bytes.length > maximumBytes) {
      throw const FormatException('store file exceeds size limit');
    }
    final native = nativeIo;
    if (native != null) {
      native.replace(_relative(target), bytes);
      return;
    }
    _checkDirectory(target.parent);
    target.parent.createSync(recursive: true);
    final staging = target.parent.createTempSync('.patch-store-');
    try {
      final temporary = File('${staging.path}/data');
      final sink = temporary.openSync(mode: FileMode.writeOnly);
      try {
        sink.writeFromSync(bytes);
        sink.flushSync();
      } finally {
        sink.closeSync();
      }
      temporary.renameSync(target.path);
    } finally {
      try {
        staging.deleteSync(recursive: true);
      } on FileSystemException {
        // Cleanup cannot change the result of an already committed rename.
      }
    }
  }

  Map<String, Object?> _emptyState() => {
    'active': null,
    'lastKnownGood': null,
    'pending': null,
    'pendingAttempt': null,
    'failures': 0,
    'blacklist': <Object?>[],
    'digests': <String, Object?>{},
  };
}
