import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class PatchStore {
  PatchStore(this.root, {this.verifyManifest});

  static const bundled = 'bundled';
  static const failureLimit = 2;
  static const maxArtifactBytes = 64 * 1024 * 1024;
  static const maxManifestBytes = 16 * 1024;
  static const maxStateBytes = 1024 * 1024;
  final Directory root;
  final bool Function(String patchId, Uint8List envelope, Uint8List artifact)?
  verifyManifest;
  final _withdrawn = <String>{};

  static bool _isPatchId(Object? value) =>
      value is String &&
      value != bundled &&
      RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$').hasMatch(value);

  static bool _isDigest(Object? value) =>
      value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  bool install(
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
      final kind = FileSystemEntity.typeSync(target.path, followLinks: false);
      if (kind != FileSystemEntityType.notFound &&
          kind != FileSystemEntityType.file) {
        return false;
      }
      // A crash may leave an artifact before the state commit. Only adopt an
      // identical orphan; a different artifact must receive a new patch ID.
      if (existing == null &&
          kind == FileSystemEntityType.file &&
          sha256.convert(_readBounded(target, maxArtifactBytes)).toString() !=
              expectedSha256) {
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

  String beginBoot() {
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
      _write(state);
      return selected;
    } on Object {
      return bundled;
    }
  }

  Uint8List? readVerified(String patchId) {
    try {
      final state = _read();
      return _verifiedBytes(patchId, state);
    } on Object {
      return null;
    }
  }

  bool markHealthy(String patchId) {
    try {
      final state = _read();
      if (state['pending'] != patchId ||
          _verifiedBytes(patchId, state) == null) {
        return false;
      }
      state['active'] = patchId;
      state['lastKnownGood'] = patchId;
      state['pending'] = null;
      state['failures'] = 0;
      _write(state);
      return true;
    } on Object {
      return false;
    }
  }

  bool withdraw(String patchId) {
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
    _checkDirectory(Directory('${root.path}/versions'));
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
      if (expected is! String ||
          FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        return null;
      }
      final bytes = _readBounded(file, maxArtifactBytes);
      if (sha256.convert(bytes).toString() != expected) return null;
      final verify = verifyManifest;
      if (verify != null) {
        final envelope = _manifest(patchId);
        if (FileSystemEntity.typeSync(envelope.path, followLinks: false) !=
                FileSystemEntityType.file ||
            !verify(patchId, _readBounded(envelope, maxManifestBytes), bytes)) {
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
    _checkDirectory(root);
    final file = File('${root.path}/state.json');
    final kind = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) return _emptyState();
    if (kind != FileSystemEntityType.file) {
      throw const FormatException('invalid state file');
    }
    final value = jsonDecode(utf8.decode(_readBounded(file, maxStateBytes)));
    if (value is! Map<String, Object?> ||
        value.length != 6 ||
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
        (value['pending'] == null && value['failures'] != 0)) {
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

  void _checkDirectory(Directory directory) {
    final kind = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (kind != FileSystemEntityType.directory &&
        kind != FileSystemEntityType.notFound) {
      throw const FormatException('invalid store directory');
    }
  }

  // ponytail: one startup owner serializes store operations; multiple owners
  // require a platform transaction lock, plus directory fsync for power loss.
  void _replace(File target, List<int> bytes, int maximumBytes) {
    if (bytes.length > maximumBytes) {
      throw const FormatException('store file exceeds size limit');
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
    'failures': 0,
    'blacklist': <Object?>[],
    'digests': <String, Object?>{},
  };
}
