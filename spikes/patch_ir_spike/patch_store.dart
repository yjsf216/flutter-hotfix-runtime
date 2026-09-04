import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class PatchStore {
  PatchStore(this.root);

  static const bundled = 'bundled';
  static const failureLimit = 2;
  final Directory root;

  bool install(String patchId, Uint8List ir, String expectedSha256) {
    if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(patchId) ||
        sha256.convert(ir).toString() != expectedSha256) {
      return false;
    }
    try {
      final versions = Directory('${root.path}/versions')
        ..createSync(recursive: true);
      final target = File('${versions.path}/$patchId.ir');
      final temporary = File('${versions.path}/.$patchId.tmp');
      final sink = temporary.openSync(mode: FileMode.writeOnly);
      sink.writeFromSync(ir);
      sink.flushSync();
      sink.closeSync();
      temporary.renameSync(target.path);
      final state = _read();
      state['active'] = patchId;
      state['failures'] = 0;
      (state['digests'] as Map<String, Object?>)[patchId] = expectedSha256;
      _write(state);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  String beginBoot() {
    try {
      final state = _read();
      final pending = state['pending'] as String?;
      if (pending != null && pending != bundled) {
        final failures = (state['failures'] as int? ?? 0) + 1;
        state['failures'] = failures;
        if (failures >= failureLimit) {
          (state['blacklist'] as List<Object?>).add(pending);
          state['active'] = state['lastKnownGood'];
        }
      }
      final selected = _select(state);
      state['pending'] = selected == bundled ? null : selected;
      _write(state);
      return selected;
    } on Object {
      return bundled;
    }
  }

  bool markHealthy(String patchId) {
    try {
      final state = _read();
      if (state['pending'] != patchId || !_validArtifact(patchId, state)) {
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

  void withdraw(String patchId) {
    try {
      final state = _read();
      final blacklist = state['blacklist'] as List<Object?>;
      if (!blacklist.contains(patchId)) blacklist.add(patchId);
      if (state['active'] == patchId) state['active'] = state['lastKnownGood'];
      state['pending'] = null;
      _write(state);
    } on Object {
      // Fail open: a withdrawal persistence failure cannot prevent bundled boot.
    }
  }

  String _select(Map<String, Object?> state) {
    final blacklist = (state['blacklist'] as List<Object?>).cast<String>();
    for (final candidate in [state['active'], state['lastKnownGood']]) {
      if (candidate is String &&
          !blacklist.contains(candidate) &&
          _validArtifact(candidate, state)) {
        return candidate;
      }
    }
    return bundled;
  }

  File _artifact(String patchId) => File('${root.path}/versions/$patchId.ir');

  bool _validArtifact(String patchId, Map<String, Object?> state) {
    final file = _artifact(patchId);
    final expected = (state['digests'] as Map<String, Object?>)[patchId];
    return expected is String &&
        FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.file &&
        sha256.convert(file.readAsBytesSync()).toString() == expected;
  }

  Map<String, Object?> _read() {
    final file = File('${root.path}/state.json');
    if (!file.existsSync()) return _emptyState();
    final value = jsonDecode(file.readAsStringSync());
    if (value is! Map<String, Object?> ||
        value['blacklist'] is! List<Object?> ||
        value['digests'] is! Map<String, Object?> ||
        value['failures'] is! int) {
      throw const FormatException('invalid state');
    }
    return value;
  }

  void _write(Map<String, Object?> state) {
    root.createSync(recursive: true);
    final temporary = File('${root.path}/.state.tmp');
    final sink = temporary.openSync(mode: FileMode.writeOnly);
    sink.writeStringSync(jsonEncode(state));
    sink.flushSync();
    sink.closeSync();
    temporary.renameSync('${root.path}/state.json');
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
