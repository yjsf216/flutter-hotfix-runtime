import 'dart:convert';
import 'dart:io';

import 'compile_dbc3_patch.dart' as compiler;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) throw ArgumentError('Dart SDK source required');
  final sdk = Directory(arguments.single).absolute;
  final spike = File.fromUri(Platform.script).parent.parent;
  final temporary = Directory.systemTemp.createTempSync('generic-class-patch-');
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
    if ((metadata['changed'] as List).length != 4 ||
        (metadata['newHelpers'] as List).isNotEmpty) {
      throw StateError(
        'expected only Box read/replace/choose and NumberBox choose',
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
      ('field-type', 'int changes = 0;', 'num changes = 0;'),
      ('field-layout', 'int changes = 0;', 'int changes = 0; int added = 0;'),
      ('constructor', 'Box(this._value);', 'Box(this._value) { changes = 7; }'),
      ('class-bound', 'class Box<T>', 'class Box<T extends Object>'),
      (
        'numeric-class-bound',
        'class NumberBox<T extends num>',
        'class NumberBox<T extends int>',
      ),
      (
        'covariant-parameter',
        'T replace(T value)',
        'T replace(covariant T value)',
      ),
    ]) {
      business.writeAsStringSync(_business(true).replaceFirst(before, after));
      final rejected = Directory('${root.path}/rejected-$name');
      var refused = false;
      try {
        await compiler.compilePatch(
          sdk: sdk,
          release: release,
          updatedUri: business.uri,
          output: rejected,
        );
      } on FormatException catch (error) {
        if (!error.message.contains('incompatible Kernel library')) rethrow;
        refused = true;
      }
      if (!refused || File('${rejected.path}/patch.bytecode').existsSync()) {
        throw StateError('generic class $name change accepted before emission');
      }
      print(
        'PASS: generic class $name change rejected before bytecode emission',
      );
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

String _business(bool patched) =>
    '''
class Box<T> {
  T _value;
  int changes = 0;
  Box(this._value);

  static X baselineAot<X>(X value) => value;

  T read() {
    changes += ${patched ? 100 : 1};
    return baselineAot<T>(_value);
  }

  T replace(T value) {
    final previous = _value;
    _value = value;
    changes += ${patched ? 20 : 2};
    return baselineAot<T>(${patched ? 'previous' : 'value'});
  }

  U choose<U extends T>(U value, {
    required U other,
    bool useOther = false,
    U Function(U)? convert,
  }) {
    changes += ${patched ? 300 : 3};
    final selected = useOther ? ${patched ? 'value : other' : 'other : value'};
    return convert == null ? baselineAot<U>(selected) : convert(selected);
  }
}

class NumberBox<T extends num> {
  T value;
  NumberBox(this.value);
  T choose(T other) => Box.baselineAot<T>(${patched ? 'other' : 'value'});
}
''';

const _entry = r'''
typedef ReadPatch = T Function<T>(Box<T> receiver);
typedef ReplacePatch = T Function<T>(Box<T> receiver, T value);
typedef ChoosePatch = U Function<T, U extends T>(Box<T> receiver, U value, {
  required U other,
  bool useOther,
  U Function(U)? convert,
});
typedef NumberPatch = T Function<T extends num>(NumberBox<T> receiver, T other);

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void typeError(void Function() invoke, String message) {
  var refused = false;
  try {
    invoke();
  } on TypeError {
    refused = true;
  }
  check(refused, message);
}

int callbackCalls = 0;
int aotCallback(int value) {
  callbackCalls++;
  return value + 3;
}

void checkPatched() {
  final integers = Box<int>(11);
  final int first = integers.read();
  check(first == 11 && integers.changes == 100, 'read<T> lost receiver type or patch');
  final int previous = integers.replace(22);
  check(previous == 11 && integers.changes == 120, 'replace<T> did not return old T');
  check(integers.read() == 22 && integers.changes == 220, 'patched field write lost');
  final int selected = integers.choose<int>(5, other: 6);
  check(selected == 6 && integers.changes == 520, 'class T + method U lost');
  check(integers.choose<int>(5, other: 6, useOther: true) == 5,
      'dependent generic named parameter lost');

  final floating = Box<double>(1.25);
  final double oldDouble = floating.replace(2.5);
  check(oldDouble == 1.25 && floating.read() == 2.5, 'double receiver instantiation lost');
  final numBox = Box<num>(1);
  final double selectedDouble = numBox.choose<double>(1.5, other: 2.5);
  check(selectedDouble == 2.5, 'distinct class num / method double arguments lost');

  final nullable = Box<String?>(null);
  final String? initialNull = nullable.read();
  check(initialNull == null && nullable.changes == 100, 'nullable class T read');
  check(nullable.replace('x') == null && nullable.read() == 'x', 'nullable T field mutation');
  final String? selectedText = nullable.choose<String?>(null, other: 'other');
  check(selectedText == 'other' &&
      nullable.choose<String?>(null, other: 'other', useOther: true) == null,
      'nullable class T / method U bound or return lost');
  check(NumberBox<int>(1).choose(2) == 2 && NumberBox<double>(1.5).choose(2.5) == 2.5,
      'numeric class bound or class argument reification lost');
}

T alternateRead<T>(Box<T> receiver) => throw StateError('partially published table');
T alternateReplace<T>(Box<T> receiver, T value) => value;

Future<void> main(List<String> arguments) async {
  final baseline = Box<int>(1);
  check(baseline.read() == 1 && baseline.changes == 1, 'baseline generic read');
  check(baseline.replace(2) == 2 && baseline.changes == 3, 'baseline generic replace');
  check(baseline.choose<int>(3, other: 4) == 3 && baseline.changes == 6,
      'baseline dependent generic choose');
  check(NumberBox<double>(1.5).choose(2.5) == 1.5, 'baseline class bound');

  final loaded = await loadModuleFromBytes(File(arguments.single).readAsBytesSync());
  check(loaded is Map, 'module export map missing');
  final module = Map<String, Object?>.from(loaded as Map);
  check(module.length == 4, 'expected exactly four changed generic class methods');
  final readId = module.entries.singleWhere((entry) => entry.value is ReadPatch).key;
  final replaceId = module.entries.singleWhere((entry) => entry.value is ReplacePatch).key;
  final chooseId = module.entries.singleWhere((entry) => entry.value is ChoosePatch).key;
  final numberId = module.entries.singleWhere((entry) => entry.value is NumberPatch).key;
  check({readId, replaceId, chooseId, numberId}.length == 4, 'typed export identities overlap');
  runtime.activateModule(module);
  checkPatched();
  check(Box<int>(0).choose<int>(4, other: 9, convert: aotCallback) == 12 && callbackCalls == 1,
      'generic class patch did not call baseline AOT callback');

  final narrow = Box<int>(1);
  final Box<num> widened = narrow;
  typeError(() { widened.replace(1.5); }, 'covariant replace accepted double in Box<int>');
  check(narrow.changes == 0, 'covariant replace entered patch body before rejecting');
  typeError(() { widened.choose<double>(1.5, other: 2.5); },
      'covariant method bound accepted double in Box<int>');
  check(narrow.changes == 0, 'covariant method bound rejection had patch side effects');

  final wrongReceiver = Box<String>('text');
  final dynamic readExport = module[readId];
  typeError(() { readExport<int>(wrongReceiver); }, 'typed receiver accepted Box<String> as Box<int>');
  check(wrongReceiver.changes == 0, 'raw/dynamic receiver reached patch body before rejecting');
  final dynamic numberExport = module[numberId];
  typeError(() { numberExport<String>(NumberBox<int>(1), 'x'); },
      'lifted numeric class bound accepted String');

  void reject(String id, Object? bad, String name) {
    final incompatible = id == readId ? bad is! ReadPatch :
        id == chooseId ? bad is! ChoosePatch : bad is! NumberPatch;
    check(incompatible, '$name fixture accidentally has a compatible ABI');
    final sentinelId = id == readId ? replaceId : readId;
    final Object sentinel = id == readId ? alternateReplace : alternateRead;
    final poisoned = <String, Object?>{
      sentinelId: sentinel,
      for (final entry in module.entries)
        if (entry.key != sentinelId && entry.key != id) entry.key: entry.value,
      id: bad,
    };
    var refused = false;
    try {
      runtime.activateModule(poisoned);
    } on FormatException {
      refused = true;
    }
    check(refused, '$name export was accepted');
    checkPatched();
  }

  reject(readId, <T>(Box<String> receiver) => throw StateError('bad receiver'),
      'wrong typed receiver');
  reject(readId, <T>(Box<T> receiver) => 'bad return', 'wrong class T return');
  reject(chooseId,
      <T, U extends int>(Box<T> receiver, U value, {required U other,
        bool useOther = false, U Function(U)? convert}) => value,
      'wrong dependent method bound');
  reject(numberId, <T extends int>(NumberBox<T> receiver, T other) => other,
      'wrong lifted class bound');

  runtime.deactivateModule();
  final restored = Box<int>(10);
  check(restored.read() == 10 && restored.changes == 1, 'withdrawal did not restore read');
  check(restored.replace(20) == 20 && restored.changes == 3, 'withdrawal did not restore replace');
  check(restored.choose<int>(4, other: 9) == 4 && restored.changes == 6,
      'withdrawal did not restore dependent method');
  check(NumberBox<int>(1).choose(2) == 1, 'withdrawal did not restore numeric class method');
  print('PASS: same-layout generic classes -> typed DBC3/AOT, reified T/U, nullable fields, '
      'AOT helper/callback, covariance, withdrawal and atomic ABI rejection');
}
''';

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError('${result.stdout}\n${result.stderr}');
  }
  stdout.write(result.stdout);
}
