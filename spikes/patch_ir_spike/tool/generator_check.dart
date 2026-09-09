import 'dart:convert';
import 'dart:io';

import 'compile_dbc3_patch.dart' as compiler;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) throw ArgumentError('Dart SDK source required');
  final sdk = Directory(arguments.single).absolute;
  final spike = File.fromUri(Platform.script).parent.parent;
  final temporary = Directory.systemTemp.createTempSync('generator-patch-');
  final root = Directory(temporary.resolveSymbolicLinksSync());
  try {
    final business = File('${root.path}/business.dart')
      ..writeAsStringSync(_business(0));
    final entry = File('${root.path}/main.dart')
      ..writeAsStringSync('''
import 'dart:async';
import 'dart:io';
import 'package:dynamic_modules/dynamic_modules.dart';
import '${spike.uri.resolve('dbc3_dispatch.dart')}' as runtime;
import '${business.uri}';
$_entry
''');
    final release = Directory('${root.path}/release');
    await compiler.compileBaseline(
      sdk: sdk,
      baselineUri: business.uri,
      entryUri: entry.uri,
      output: release,
    );
    business.writeAsStringSync(_business(100));
    final patch = Directory('${root.path}/patch');
    await compiler.compilePatch(
      sdk: sdk,
      release: release,
      updatedUri: business.uri,
      output: patch,
    );
    final metadata =
        jsonDecode(File('${patch.path}/metadata.json').readAsStringSync())
            as Map;
    if ((metadata['changed'] as List).length != 2 ||
        (metadata['newHelpers'] as List).isNotEmpty) {
      throw StateError('only syncValues and asyncValues should be patched');
    }
    final snapshot = '${root.path}/baseline.snapshot';
    await _run('${sdk.path}/xcodebuild/ReleaseARM64/gen_snapshot_product', [
      '--snapshot-kind=app-aot-elf',
      '--elf=$snapshot',
      '${release.path}/baseline.aot.dill',
    ]);
    await _run('${sdk.path}/xcodebuild/ReleaseARM64/dartaotruntime_product', [
      snapshot,
      '${patch.path}/patch.bytecode',
    ]);
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

String _business(int extra) =>
    '''
class Producer {
  int starts = 0;
  int exits = 0;
  int delivered = 0;

  static int aot(int value) => value + 7;

  Iterable<int> syncValues(int count, {bool fail = false}) sync* {
    starts++;
    try {
      for (var i = 0; i < count; i++) {
        if (fail && i == 1) throw StateError('generator failure');
        delivered++;
        yield aot(i + $extra);
      }
    } finally {
      exits++;
    }
  }

  Stream<int> asyncValues(int count, {bool fail = false}) async* {
    starts++;
    try {
      for (var i = 0; i < count; i++) {
        await Future<void>.value();
        if (fail && i == 1) throw StateError('generator failure');
        delivered++;
        yield aot(i + $extra);
      }
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      exits++;
    }
  }

  Iterable<int> syncChain(int count, {bool fail = false}) sync* {
    yield* syncValues(count, fail: fail);
  }

  Stream<int> asyncChain(int count, {bool fail = false}) async* {
    yield* asyncValues(count, fail: fail);
  }
}
''';

const _entry = r'''
void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void values(List<int> actual, List<int> expected, String message) {
  check(actual.join(',') == expected.join(','), '$message: $actual');
}

void counts(Producer p, int starts, int exits, int delivered, String message) {
  check(p.starts == starts && p.exits == exits && p.delivered == delivered,
      '$message: starts=${p.starts}, exits=${p.exits}, delivered=${p.delivered}');
}

Future<void> main(List<String> arguments) async {
  final module = await loadModuleFromBytes(File(arguments.single).readAsBytesSync());
  final baseline = Producer();
  values(baseline.syncChain(2).toList(), [7, 8], 'baseline sync');
  values(await baseline.asyncChain(2).toList(), [7, 8], 'baseline async');
  counts(baseline, 2, 2, 4, 'baseline completion');

  final sync = Producer();
  final iterable = sync.syncValues(3);
  counts(sync, 0, 0, 0, 'sync creation must be lazy');
  final iterator = iterable.iterator;
  counts(sync, 0, 0, 0, 'iterator creation must be lazy');
  final async = Producer();
  final stream = async.asyncValues(2);
  counts(async, 0, 0, 0, 'async creation must be lazy');

  runtime.activateModule(module);
  check(iterator.moveNext() && iterator.current == 107,
      'iterator created before activation must pick patch at first moveNext');
  counts(sync, 1, 0, 1, 'sync first yield must suspend');
  runtime.deactivateModule();
  check(iterator.moveNext() && iterator.current == 108,
      'in-flight sync generator lost selected patch');
  check(iterator.moveNext() && iterator.current == 109,
      'in-flight sync generator did not finish selected patch');
  check(!iterator.moveNext(), 'sync iterator did not terminate');
  counts(sync, 1, 1, 3, 'sync completion must run finally once');
  values(sync.syncValues(1).toList(), [7], 'future sync entry must use baseline');
  counts(sync, 2, 2, 4, 'baseline after withdrawal');

  runtime.activateModule(module);
  values(iterable.toList(), [107, 108, 109], 'repeat iteration must be independent');
  counts(sync, 3, 3, 7, 'repeat iteration completion');
  values(await stream.toList(), [107, 108],
      'stream created before activation must pick patch at subscription');
  counts(async, 1, 1, 2, 'async completion must await finally');

  final nested = Producer();
  values(nested.syncChain(2).toList(), [107, 108], 'baseline sync yield* into patch');
  values(await nested.asyncChain(2).toList(), [107, 108],
      'baseline async yield* into patch');
  counts(nested, 2, 2, 4, 'nested yield* completion');
  final empty = Producer();
  values(empty.syncValues(0).toList(), [], 'empty sync generator');
  values(await empty.asyncValues(0).toList(), [], 'empty async generator');
  counts(empty, 2, 2, 0, 'empty generators must run finally once');

  final partial = Producer();
  final partialIterator = partial.syncChain(3).iterator;
  check(partialIterator.moveNext() && partialIterator.current == 107,
      'partial sync iteration did not enter patch');
  counts(partial, 1, 0, 1, 'partial sync iteration must not eagerly drain body');

  final syncFailure = Producer();
  var sawSyncError = false;
  try {
    syncFailure.syncChain(3, fail: true).toList();
  } on StateError catch (error) {
    check(error.message == 'generator failure', 'sync exception was replaced');
    sawSyncError = true;
  }
  check(sawSyncError, 'sync exception was swallowed');
  counts(syncFailure, 1, 1, 1, 'sync exception must unwind finally');
  final asyncFailure = Producer();
  var sawAsyncError = false;
  try {
    await asyncFailure.asyncChain(3, fail: true).toList();
  } on StateError catch (error) {
    check(error.message == 'generator failure', 'async exception was replaced');
    sawAsyncError = true;
  }
  check(sawAsyncError, 'async exception was swallowed');
  counts(asyncFailure, 1, 1, 1, 'async exception must await finally');

  final suspended = Producer();
  final subscription = StreamIterator<int>(suspended.asyncChain(3));
  check(await subscription.moveNext() && subscription.current == 107,
      'async first yield did not select patch');
  counts(suspended, 1, 0, 1, 'async first event must suspend');
  runtime.deactivateModule();
  check(await subscription.moveNext() && subscription.current == 108,
      'in-flight async generator lost selected patch');
  check(await subscription.moveNext() && subscription.current == 109,
      'in-flight async generator did not finish selected patch');
  check(!await subscription.moveNext(), 'async subscription did not finish');
  counts(suspended, 1, 1, 3, 'async completion after withdrawal');
  values(await suspended.asyncValues(1).toList(), [7],
      'future async entry must use baseline');
  counts(suspended, 2, 2, 4, 'async baseline after withdrawal');

  runtime.activateModule(module);
  final cancelled = Producer();
  final nestedSubscription = StreamIterator<int>(cancelled.asyncChain(5));
  check(await nestedSubscription.moveNext() && nestedSubscription.current == 107,
      'nested cancellable stream did not enter patch');
  await nestedSubscription.cancel();
  counts(cancelled, 1, 1, 1, 'nested cancellation must await finally without draining');
  runtime.deactivateModule();
  print('PASS: ordinary sync*/async* -> automatic patch points -> DBC3/AOT, '
      'lazy iteration, yield*, finally, exceptions, cancellation and withdrawal');
}
''';

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError('${result.stdout}\n${result.stderr}');
  }
  stdout.write(result.stdout);
}
