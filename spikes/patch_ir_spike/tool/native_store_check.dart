import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import '../native_store_io.dart';
import '../patch_store.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<bool> writeWorker(
  String rootPath,
  String libraryPath,
  int index,
  Uint8List bytes,
  String hash,
) => Isolate.run(() {
  final root = Directory(rootPath);
  final owner = NativeStoreIo(root, DynamicLibrary.open(libraryPath));
  final writer = PatchStore(root, nativeIo: owner);
  try {
    for (var item = 0; item < 10; item++) {
      if (!writer.install('p$index-$item', bytes, hash)) return false;
    }
    return true;
  } finally {
    writer.close();
  }
});

Future<void> main(List<String> arguments) async {
  final libraryPath = File(arguments.single).absolute.path;
  final temporary = Directory.systemTemp.createTempSync('native-store-dart-');
  final root = Directory('${temporary.resolveSymbolicLinksSync()}/store');
  final io = NativeStoreIo(root, DynamicLibrary.open(libraryPath));
  final store = PatchStore(root, nativeIo: io);
  final bytes = Uint8List.fromList(utf8.encode('immutable payload'));
  final hash = sha256.convert(bytes).toString();
  try {
    check(store.install('p0', bytes, hash), 'native install');
    check(
      store.beginBoot() == 'p0' && store.markHealthy('p0'),
      'native health',
    );
    check(
      utf8.decode(store.readVerified('p0')!) == 'immutable payload',
      'native read',
    );
    check(store.beginBoot() == 'p0', 'begin existing boot');
    check(store.install('next', bytes, hash), 'stage next while boot pending');
    check(
      store.markHealthy('p0') && store.beginBoot() == 'next',
      'health erased concurrently staged update',
    );
    check(store.markHealthy('next'), 'next health');
    final other = PatchStore(
      root,
      nativeIo: NativeStoreIo(root, DynamicLibrary.open(libraryPath)),
    );
    try {
      final firstAttempt = store.beginBootAttempt()!;
      final secondAttempt = other.beginBootAttempt()!;
      final stateFile = File('${root.path}/state.json');
      final beforeLateAck = stateFile.readAsStringSync();
      check(
        !store.markBootHealthy(firstAttempt),
        'stale native owner acknowledged',
      );
      check(!store.markHealthy('next'), 'legacy API cleared newer native boot');
      check(
        store.rejectBootAndBeginFallback(firstAttempt)?.superseded == true,
        'stale native failure rejected newer pending patch',
      );
      check(
        stateFile.readAsStringSync() == beforeLateAck,
        'stale native ack changed pending/failures',
      );
      check(
        other.markBootHealthy(secondAttempt),
        'current native owner health',
      );
    } finally {
      other.close();
    }
    check(store.install('native-bad', bytes, hash), 'stage explicit failure');
    final failingAttempt = store.beginBootAttempt()!;
    check(
      store.install('native-next', bytes, hash),
      'stage concurrent successor',
    );
    final rejection = store.rejectBootAndBeginFallback(failingAttempt)!;
    check(
      !rejection.superseded && rejection.fallback?.patchId == 'next',
      'native failure did not atomically select LKG',
    );
    check(store.markBootHealthy(rejection.fallback!), 'native fallback health');
    final beforeWorkers =
        jsonDecode(File('${root.path}/state.json').readAsStringSync()) as Map;
    check(
      beforeWorkers['active'] == 'native-next' &&
          (beforeWorkers['blacklist'] as List).contains('native-bad'),
      'native fallback erased rejection or concurrent successor',
    );
    final existingCount = (beforeWorkers['digests'] as Map).length;
    var rejected = false;
    io.transaction(() {
      try {
        io.transaction(() {});
      } on StateError {
        rejected = true;
      }
    });
    check(rejected, 'nested transaction accepted');
    final outcomes = await Future.wait(
      List.generate(
        8,
        (index) => writeWorker(root.path, libraryPath, index, bytes, hash),
      ),
    );
    check(outcomes.every((value) => value), 'concurrent install failed');
    final state =
        jsonDecode(File('${root.path}/state.json').readAsStringSync()) as Map;
    check(
      (state['digests'] as Map).length == existingCount + 80,
      'lost native transaction update',
    );
    final file = File('${root.path}/versions/p0.ir');
    file.renameSync('${file.path}.original');
    Link(file.path).createSync('${file.path}.original');
    check(store.readVerified('p0') == null, 'native symlink read accepted');
    check(!store.install('p0', bytes, hash), 'native symlink write accepted');
    Link(file.path).deleteSync();
    File('${file.path}.original').renameSync(file.path);
    check(store.readVerified('p0') != null, 'preserved LKG lost');
    print(
      'PASS: Dart FFI native store + boot-attempt ownership + 8-isolate transactions + symlink rejection + LKG',
    );
  } finally {
    store.close();
    temporary.deleteSync(recursive: true);
  }
}
