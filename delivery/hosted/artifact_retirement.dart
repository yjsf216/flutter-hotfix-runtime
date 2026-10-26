import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Origin deletion/CDN invalidation is an explicit deployment capability.
/// Its receipt must confirm both operations; exit zero alone is insufficient.
Future<void> purgeArtifacts(String executable, List<String> hashes) async {
  if (!executable.startsWith('/') ||
      !File(executable).existsSync() ||
      hashes.isEmpty ||
      hashes.length > 1000 ||
      hashes.any((h) => !RegExp(r'^[a-f0-9]{64}$').hasMatch(h))) {
    throw ArgumentError('invalid retirement adapter request');
  }
  final env = Map<String, String>.from(Platform.environment)
    ..removeWhere(
      (key, _) =>
          key.startsWith('HOTFIX_') &&
          !{
            'HOTFIX_OSS_CONFIG',
            'HOTFIX_OSS_BUCKET',
            'HOTFIX_OSS_PREFIX',
            'HOTFIX_CDN_BLOB_BASE',
            'HOTFIX_RETIRE_CONFIRM',
            'HOTFIX_RETIRE_OSSUTIL',
            'HOTFIX_RETIRE_CDNCLI',
            'HOTFIX_RETIRE_STATE',
            'HOTFIX_CDN_PROFILE',
          }.contains(key),
    );
  final process = await Process.start(
    executable,
    const [],
    environment: env,
    includeParentEnvironment: false,
  );
  final bytes = <int>[];
  final output = process.stdout.forEach((chunk) {
    if (bytes.length + chunk.length > 128 * 1024)
      throw StateError('retirement receipt too large');
    bytes.addAll(chunk);
  });
  final errors = process.stderr.drain<void>();
  var exited = false;
  final exit = process.exitCode.then((value) {
    exited = true;
    return value;
  });
  process.stdin.write(jsonEncode({'schemaVersion': 1, 'hashes': hashes}));
  try {
    final results = await Future.wait<dynamic>([
      exit,
      output,
      errors,
      process.stdin.close(),
    ], eagerError: true).timeout(const Duration(seconds: 90));
    final status = results[0];
    final receipt = jsonDecode(utf8.decode(bytes));
    if (status != 0 ||
        receipt is! Map ||
        receipt['originDeleted'] != true ||
        receipt['cdnPurged'] != true ||
        receipt['hashes'] is! List ||
        (receipt['hashes'] as List).length != hashes.length ||
        !(receipt['hashes'] as List).toSet().containsAll(hashes)) {
      throw StateError('object/CDN retirement not confirmed');
    }
  } finally {
    if (!exited) process.kill(ProcessSignal.sigkill);
    await exit;
    await errors;
  }
}

/// Serializes enabled lifecycle mutations with uploads to prevent shared-blob GC races.
class SerialMutations {
  Future<void> tail = Future.value();
  int queued = 0;
  Future<void> run(Future<void> Function() action) async {
    if (queued >= 8) throw StateError('retention mutation queue full');
    queued++;
    final previous = tail;
    final done = Completer<void>();
    tail = done.future;
    try {
      await previous;
      await action();
    } finally {
      queued--;
      done.complete();
    }
  }
}
