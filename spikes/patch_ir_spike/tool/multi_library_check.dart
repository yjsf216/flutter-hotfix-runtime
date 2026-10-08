import 'dart:convert';
import 'dart:io';
import 'compile_dbc3_patch.dart' as compiler;

Future<void> main(List<String> args) async {
  final sdk = Directory(args.single).absolute;
  final spike = File.fromUri(Platform.script).parent.parent;
  final temp = Directory.systemTemp.createTempSync('multi-library-');
  final root = Directory(temp.resolveSymbolicLinksSync());
  Future<void> run(String name, List<String> arguments) async {
    final result = await Process.run(
      '${sdk.path}/xcodebuild/ReleaseARM64/$name',
      arguments,
    );
    if (result.exitCode != 0)
      throw StateError('${result.stdout}\n${result.stderr}');
    stdout.write(result.stdout);
  }

  try {
    final business = Directory('${root.path}/lib')..createSync();
    final a = File('${business.path}/a.dart')
      ..writeAsStringSync(
        "import 'b.dart' as b;\nint same() => 1;\nint zero() => 0;\nint forward(b.Box box) => calc(box);\nint calc(b.Box box) => same() + b.same() + box.value;\n",
      );
    final b = File('${business.path}/b.dart')
      ..writeAsStringSync(
        "import 'a.dart' as a;\nenum Kind { one, two }\nclass Box { final int value; Box(this.value); int get doubled => value * 2; }\nint same() => 2 + a.zero();\n",
      );
    final entry = File('${root.path}/main.dart')
      ..writeAsStringSync('''
import 'dart:io';
import 'package:dynamic_modules/dynamic_modules.dart';
import '${spike.uri.resolve('dbc3_dispatch.dart')}' as runtime;
import '${a.uri}' as a;
import '${b.uri}' as b;
Future<void> main(List<String> args) async {
  final box = b.Box(3);
  if (a.calc(box) != 6) throw StateError('baseline');
  runtime.activateModule(await loadModuleFromBytes(File(args.single).readAsBytesSync()));
  if (a.same() != 10 || b.same() != 20 || a.calc(box) != 86 || a.forward(box) != 86) throw StateError('cross-library dispatch/type/ID');
  runtime.deactivateModule();
  if (a.calc(box) != 6) throw StateError('withdrawal');
  print('PASS: multi-library same-name IDs, cross-library calls/types and withdrawal in real AOT');
}
''');
    final release = Directory('${root.path}/release');
    await compiler.compileBaseline(
      sdk: sdk,
      baselineUri: a.uri,
      entryUri: entry.uri,
      output: release,
      patchRoot: business.uri,
    );
    a.writeAsStringSync(
      "import 'b.dart' as b;\nint same() => 10;\nint zero() => 0;\nint forward(b.Box box) => calc(box);\nint calc(b.Box box) => 2 * (same() + b.same() + box.value) + b.helper();\n",
    );
    b.writeAsStringSync(
      "import 'a.dart' as a;\nenum Kind { one, two }\nclass Box { final int value; Box(this.value); int get doubled => value * 2; }\nint same() => helper();\nint helper() => 20 + a.zero();\n",
    );
    final patch = Directory('${root.path}/patch');
    await compiler.compilePatch(
      sdk: sdk,
      release: release,
      updatedUri: a.uri,
      output: patch,
    );
    final metadata =
        jsonDecode(File('${patch.path}/metadata.json').readAsStringSync())
            as Map;
    if ((metadata['changed'] as List).length != 3)
      throw StateError('Expected all three changes');
    if ((metadata['newHelpers'] as List).length != 1)
      throw StateError('Expected cross-library helper');
    final snapshot = '${root.path}/app.snapshot';
    await run('gen_snapshot_product', [
      '--snapshot-kind=app-aot-elf',
      '--elf=$snapshot',
      '${release.path}/baseline.aot.dill',
    ]);
    await run('dartaotruntime_product', [
      snapshot,
      '${patch.path}/patch.bytecode',
    ]);
    final validSource = b.readAsStringSync();
    b.writeAsStringSync(
      validSource.replaceFirst('one, two', 'one, two, three'),
    );
    var enumRefused = false;
    try {
      await compiler.compilePatch(
        sdk: sdk,
        release: release,
        updatedUri: a.uri,
        output: Directory('${root.path}/invalid-enum'),
      );
    } on FormatException {
      enumRefused = true;
    }
    if (!enumRefused ||
        File('${root.path}/invalid-enum/patch.bytecode').existsSync())
      throw StateError('enum structure change accepted');
    print('PASS: enum structure change rejected');
    b.writeAsStringSync(
      "import 'a.dart' as a;\nenum Kind { one, two }\nclass Box { final int value; final int extra = 1; Box(this.value); int get doubled => value * 2; }\nint same() => helper();\nint helper() => 20 + a.zero();\n",
    );
    var refused = false;
    try {
      await compiler.compilePatch(
        sdk: sdk,
        release: release,
        updatedUri: a.uri,
        output: Directory('${root.path}/invalid'),
      );
    } on FormatException {
      refused = true;
    }
    if (!refused || File('${root.path}/invalid/patch.bytecode').existsSync())
      throw StateError('layout change accepted');
    print('PASS: cross-library field layout change rejected');
  } finally {
    temp.deleteSync(recursive: true);
  }
}
