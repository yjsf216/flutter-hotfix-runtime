import 'dart:convert';
import 'dart:io';

import 'compile_dbc3_patch.dart' as compiler;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) throw ArgumentError('Dart SDK source required');
  final sdk = Directory(arguments.single).absolute;
  final spike = File.fromUri(Platform.script).parent.parent;
  final temporary = Directory.systemTemp.createTempSync('generic-patch-');
  final root = Directory(temporary.resolveSymbolicLinksSync());
  try {
    final business = File('${root.path}/business.dart')
      ..writeAsStringSync(_business(false));
    final entry = File('${root.path}/main.dart')
      ..writeAsStringSync('''
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
    business.writeAsStringSync(_business(true));
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
    if ((metadata['changed'] as List).length != 5 ||
        (metadata['newHelpers'] as List).isNotEmpty) {
      throw StateError(
        'only choose, later, optional, bounded and sequence should be patched',
      );
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

    for (final (name, before, after) in [
      ('bounds', 'T choose<T extends num>', 'T choose<T extends int>'),
      ('dependent-bounds', 'U extends T', 'U extends num'),
      (
        'named-signature',
        'bool useOther = false,',
        'bool useOther = false, int extra = 0,',
      ),
      ('return-signature', 'T optional<T>', 'Object? optional<T>'),
      (
        'async-return-signature',
        'Future<T> later<T>',
        'Future<Object?> later<T>',
      ),
    ]) {
      business.writeAsStringSync(_business(true).replaceFirst(before, after));
      final rejected = Directory('${root.path}/rejected-$name');
      var sawRejection = false;
      try {
        await compiler.compilePatch(
          sdk: sdk,
          release: release,
          updatedUri: business.uri,
          output: rejected,
        );
      } on FormatException catch (error) {
        if (!error.message.contains('incompatible Kernel library')) rethrow;
        sawRejection = true;
      }
      if (!sawRejection ||
          File('${rejected.path}/patch.bytecode').existsSync()) {
        throw StateError(
          'generic $name change was not rejected before emission',
        );
      }
      print('PASS: generic $name change rejected before bytecode emission');
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

String _business(bool patched) =>
    '''
class GenericApi {
  int calls = 0;

  static T baselineAot<T>(T value) => value;

  T choose<T extends num>(T value, {
    required T other,
    bool useOther = false,
    T Function(T)? convert,
  }) {
    calls++;
    final result = useOther ? ${patched ? 'value : other' : 'other : value'};
    return convert == null ? baselineAot<T>(result) : convert(result);
  }

  Future<T> later<T>(T value, {
    required T other,
    T Function(T)? convert,
  }) async {
    await Future<void>.value();
    final result = ${patched ? 'other' : 'value'};
    return convert == null ? baselineAot<T>(result) : convert(result);
  }
}

T optional<T>(T value, [T? other]) =>
    GenericApi.baselineAot<T>(${patched ? 'other ?? value' : 'value'});

U bounded<T extends num, U extends T>(T first, U other) =>
    ${patched ? 'GenericApi.baselineAot<U>(first as U)' : 'other'};

Iterable<T> sequence<T>(T first, T second) sync* {
  yield GenericApi.baselineAot<T>(first);
  ${patched ? 'yield GenericApi.baselineAot<T>(second);' : ''}
}
''';

const _entry = r'''
typedef ChoosePatch = T Function<T extends num>(GenericApi receiver, T value, {
  required T other,
  bool useOther,
  T Function(T)? convert,
});
typedef OptionalPatch = T Function<T>(T value, [T? other]);
typedef BoundedPatch = U Function<T extends num, U extends T>(T first, U other);
typedef SequencePatch = Iterable<T> Function<T>(T first, T second);
typedef AsyncPatch = Future<T> Function<T>(GenericApi receiver, T value, {
  required T other,
  T Function(T)? convert,
});

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

int callbackCalls = 0;
int aotCallback(int value) {
  callbackCalls++;
  return value + 3;
}

final asyncFailure = StateError('AOT callback failure through generic async patch');
int throwingAotCallback(int value) => throw asyncFailure;

Future<void> checkAsyncPatched(GenericApi api) async {
  final int number = await api.later<int>(1, other: 2);
  final String text = await api.later<String>('before', other: 'after');
  final String? nullable = await api.later<String?>(null, other: 'nullable');
  final String? absent = await api.later<String?>('before', other: null);
  check(number == 2 && text == 'after' && nullable == 'nullable' && absent == null,
      'generic Future<T> lost T or nullable return value after await');
}

void checkPatched(GenericApi api) {
  final int integer = api.choose<int>(4, other: 9);
  final double floating = api.choose<double>(1.25, other: 2.5);
  check(integer == 9 && floating == 2.5, 'generic num bound or return type lost');
  check(api.choose<int>(4, other: 9, useOther: true) == 4,
      'named parameter or named default lost');
  final String text = optional<String>('before', 'after');
  final int number = optional<int>(1, 2);
  check(text == 'after' && number == 2, 'top-level type arguments lost');
  check(optional<String>('only') == 'only', 'optional positional default lost');
  final String? nullable = optional<String?>(null, 'x');
  check(nullable == 'x' && optional<String?>(null) == null,
      'nullable type argument or nullable optional default lost');
  final int boundedInteger = bounded<num, int>(41, 9);
  final double boundedDouble = bounded<num, double>(4.5, 2.5);
  check(boundedInteger == 41 && boundedDouble == 4.5,
      'dependent bounds, type argument vector or U return type lost');
  check(sequence<String>('a', 'b').join(',') == 'a,b', 'generic sync* patch lost');
}

T alternateChoose<T extends num>(GenericApi receiver, T value, {
  required T other,
  bool useOther = false,
  T Function(T)? convert,
}) => value;

T alternateOptional<T>(T value, [T? other]) => value;

Future<void> main(List<String> arguments) async {
  final api = GenericApi();
  check(api.choose<int>(4, other: 9) == 4, 'baseline generic method');
  check(api.choose<int>(4, other: 9, useOther: true) == 9, 'baseline named argument');
  check(optional<String>('before', 'after') == 'before', 'baseline top-level generic');
  check(optional<String?>(null, 'x') == null && optional<String?>(null) == null,
      'baseline nullable optional');
  check(bounded<num, int>(41, 9) == 9 && bounded<num, double>(4.5, 2.5) == 2.5,
      'baseline dependent-bound function');
  check(sequence<int>(1, 2).join(',') == '1', 'baseline generic generator');
  check(await api.later<String>('before', other: 'after') == 'before',
      'baseline generic Future<T>');

  final result = await loadModuleFromBytes(File(arguments.single).readAsBytesSync());
  check(result is Map, 'module map missing');
  final module = Map<String, Object?>.from(result as Map);
  check(module.length == 5, 'expected exactly five changed generic functions');
  final chooseId = module.entries.singleWhere((entry) => entry.value is ChoosePatch).key;
  final optionalId = module.entries.singleWhere((entry) => entry.value is OptionalPatch).key;
  final boundedId = module.entries.singleWhere((entry) => entry.value is BoundedPatch).key;
  final sequenceId = module.entries.singleWhere((entry) => entry.value is SequencePatch).key;
  final asyncId = module.entries.singleWhere((entry) => entry.value is AsyncPatch).key;
  check({chooseId, optionalId, boundedId, sequenceId, asyncId}.length == 5, 'generic export identities overlap');

  final pending = sequence<String>('lazy', 'patch').iterator;
  runtime.activateModule(module);
  checkPatched(api);
  check(pending.moveNext() && pending.current == 'lazy', 'generic iterator first element');
  check(pending.moveNext() && pending.current == 'patch',
      'generic iterator created before activation did not select patch');
  check(!pending.moveNext(), 'generic iterator did not terminate');
  check(api.choose<int>(4, other: 9, convert: aotCallback) == 12,
      'generic patch did not call baseline AOT callback');
  check(callbackCalls == 1, 'AOT callback call count');
  await checkAsyncPatched(api);
  check(await api.later<int>(4, other: 9, convert: aotCallback) == 12 && callbackCalls == 2,
      'generic async patch did not call unchanged AOT callback after await');
  var sawAsyncError = false;
  try {
    await api.later<int>(4, other: 9, convert: throwingAotCallback);
  } on StateError catch (error, stack) {
    check(identical(error, asyncFailure) && stack.toString().isNotEmpty,
        'generic async boundary replaced the AOT exception or lost its stack');
    sawAsyncError = true;
  }
  check(sawAsyncError, 'generic async Future swallowed the AOT callback exception');
  var sawTypeError = false;
  try {
    bounded<num, int>(1.5, 2);
  } on TypeError {
    sawTypeError = true;
  }
  check(sawTypeError, 'dependent U cast silently used the first num type argument');

  void reject(String badId, Object? bad, String name) {
    check(badId == chooseId ? bad is! ChoosePatch :
        badId == optionalId ? bad is! OptionalPatch :
        badId == boundedId ? bad is! BoundedPatch : bad is! AsyncPatch,
        '$name fixture accidentally has a compatible function type');
    final sentinelId = badId == chooseId ? optionalId : chooseId;
    final Object sentinel = badId == chooseId ? alternateOptional : alternateChoose;
    // Put a valid, behavior-changing replacement before the invalid export.
    // Rejection must preserve the complete previously activated module table.
    final poisoned = <String, Object?>{
      sentinelId: sentinel,
      for (final entry in module.entries)
        if (entry.key != sentinelId && entry.key != badId) entry.key: entry.value,
      badId: bad,
    };
    var refused = false;
    try {
      runtime.activateModule(poisoned);
    } on FormatException {
      refused = true;
    }
    check(refused, '$name export was accepted');
    checkPatched(api);
  }

  reject(chooseId,
      (GenericApi receiver, num value, {required num other,
        bool useOther = false, num Function(num)? convert}) => value,
      'nongeneric');
  reject(chooseId,
      <T extends int>(GenericApi receiver, T value, {required T other,
        bool useOther = false, T Function(T)? convert}) => value,
      'wrong bounds');
  reject(chooseId,
      <T extends num>(GenericApi receiver, T value, {required T other,
        bool wrongName = false, T Function(T)? convert}) => value,
      'wrong named parameter');
  reject(chooseId,
      <T extends num>(GenericApi receiver, T value, {required T other,
        bool useOther = false, T Function(T)? convert}) => 'wrong',
      'wrong return type');
  reject(optionalId, <T>(T value, T? other) => value,
      'required positional instead of optional');
  reject(boundedId, <T extends num, U extends int>(T first, U other) => other,
      'wrong dependent bound');
  reject(asyncId, <T>(GenericApi receiver, T value, {
    required T other, T Function(T)? convert,
  }) async => 'wrong', 'Future<String> instead of Future<T>');
  await checkAsyncPatched(api);

  final inFlight = api.later<String>('before', other: 'after');
  runtime.deactivateModule();
  check(await inFlight == 'after', 'in-flight generic Future lost its selected patch');
  check(await api.later<String>('before', other: 'after') == 'before',
      'withdrawal did not restore generic async baseline');
  check(api.choose<int>(4, other: 9) == 4, 'withdrawal did not restore generic method');
  check(optional<String>('before', 'after') == 'before', 'withdrawal did not restore top-level function');
  check(optional<String?>(null, 'x') == null, 'withdrawal did not restore nullable optional');
  check(bounded<num, int>(41, 9) == 9 && bounded<num, double>(4.5, 2.5) == 2.5,
      'withdrawal did not restore dependent-bound function');
  check(sequence<String>('a', 'b').join(',') == 'a', 'withdrawal did not restore generic generator');
  print('PASS: typed generic DBC3/AOT dispatch, nullable/dependent bounds, named/default/optional arguments, '
      'callback, Future<T>, async exceptions, sync*, withdrawal and atomic incompatible-export rejection');
}
''';

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError('${result.stdout}\n${result.stderr}');
  }
  stdout.write(result.stdout);
}
