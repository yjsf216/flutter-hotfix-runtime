import 'dart:io';
import 'compile_dbc3_patch.dart' as compiler;

Future<void> main(List<String> args) async {
  final sdk = Directory(args.single).absolute;
  final spike = File.fromUri(Platform.script).parent.parent;
  final temp = Directory.systemTemp.createTempSync('multi-mixin-');
  final root = Directory(temp.resolveSymbolicLinksSync());
  try {
    final lib = Directory('${root.path}/lib')..createSync();
    final a = File('${lib.path}/a.dart');
    final b = File('${lib.path}/b.dart');
    void sources(bool patched) {
      a.writeAsStringSync(
        "import 'b.dart';\nclass Use with Monitor {}\nint offset() => ${patched ? 20 : 10};\nint calculate() ${patched ? '{ final callback = Use().value; return callback() + offset(); }' : '=> Use().value() + offset();'}\n",
      );
      b.writeAsStringSync(
        'mixin Monitor { int _value() => ${patched ? 2 : 1}; int value() => _value(); }\n',
      );
    }

    sources(false);
    final entry = File('${root.path}/main.dart')
      ..writeAsStringSync('''
import 'dart:io';
import 'package:dynamic_modules/dynamic_modules.dart';
import '${spike.uri.resolve('dbc3_dispatch.dart')}' as runtime;
import '${a.uri}';
Future<void> main(List<String> args) async {
  if (calculate() != 11) throw StateError('baseline');
  runtime.activateModule(await loadModuleFromBytes(File(args.single).readAsBytesSync()));
  if (calculate() != 22) throw StateError('private mixin dispatch');
  runtime.deactivateModule();
  if (calculate() != 11) throw StateError('withdrawal');
  print('PASS: cross-library private mixin dispatch and withdrawal in real AOT');
}
''');
    final release = Directory('${root.path}/release');
    await compiler.compileBaseline(
      sdk: sdk,
      baselineUri: a.uri,
      entryUri: entry.uri,
      output: release,
      patchRoot: lib.uri,
    );
    sources(true);
    final patch = Directory('${root.path}/patch');
    await compiler.compilePatch(
      sdk: sdk,
      release: release,
      updatedUri: a.uri,
      output: patch,
    );
    final snapshot = '${root.path}/app.snapshot';
    for (final command in [
      [
        'gen_snapshot_product',
        '--snapshot-kind=app-aot-elf',
        '--elf=$snapshot',
        '${release.path}/baseline.aot.dill',
      ],
      ['dartaotruntime_product', snapshot, '${patch.path}/patch.bytecode'],
    ]) {
      final result = await Process.run(
        '${sdk.path}/xcodebuild/ReleaseARM64/${command.first}',
        command.skip(1).toList(),
      );
      if (result.exitCode != 0)
        throw StateError('${result.stdout}\n${result.stderr}');
      stdout.write(result.stdout);
    }
  } finally {
    temp.deleteSync(recursive: true);
  }
}
