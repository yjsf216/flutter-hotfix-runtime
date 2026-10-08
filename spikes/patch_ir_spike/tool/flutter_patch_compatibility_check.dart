import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'compile_dbc3_patch.dart' as compiler;

/// Real Flutter Kernel/DBC3 regression matrix; device rendering is a separate
/// check. All candidates use one frozen release, including rejection cases.
Future<void> main(List<String> args) async {
  if (args.length != 5) {
    throw ArgumentError('SDK_SOURCE FLUTTER_SDK GEN_SNAPSHOT PACKAGES OUTPUT');
  }
  final output = Directory(args[4]).absolute;
  if (output.existsSync()) throw StateError('Use a fresh output');
  final lib = Directory('${output.path}/lib')..createSync(recursive: true);
  final mainFile = File('${lib.path}/main.dart');
  final priceFile = File('${lib.path}/price.dart');
  final entry = File('${lib.path}/entry.dart');
  final release = Directory('${output.path}/release');
  final platform = Directory(args[1]).absolute.uri.resolve(
    'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
  );
  const source = '''import 'package:flutter/material.dart';
import 'price.dart';
class Badge extends StatelessWidget {
  const Badge(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) => Text(label);
}
class MatrixApp extends StatelessWidget {
  const MatrixApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
    home: const Scaffold(body: Badge('baseline')),
  );
}
int total(int amount) => price(amount);
Future<int> later(int amount) async => total(amount);
List<int> transform(List<int> values) => values.map((value) => total(value)).toList();
String label(bool valid) => valid ? 'valid' : 'invalid';
Object payload() => const <Object>[Badge('baseline'), <String, Object>{'widget': Badge('baseline')}];
void main() => runApp(const MatrixApp());
''';
  const price = 'int price(int amount) => amount * 2;\n';
  mainFile.writeAsStringSync(source);
  priceFile.writeAsStringSync(price);
  final runtime = File.fromUri(
    Platform.script,
  ).parent.parent.uri.resolve('lib/dbc3_dispatch.dart');
  entry.writeAsStringSync('''import 'main.dart' as app;
import '$runtime';
Future<void> main(List<String> args) async {
  final patch = await bootSignedModule(args);
  app.main();
  if (patch != null) commitModuleHealth(patch);
}
''');
  await compiler.compileBaseline(
    sdk: Directory(args[0]).absolute,
    baselineUri: mainFile.uri,
    entryUri: entry.uri,
    output: release,
    targetName: 'flutter',
    patchRoot: lib.uri,
    platformDillUri: platform,
    packagesFileUri: File(args[3]).absolute.uri,
    genSnapshotUri: File(args[2]).absolute.uri,
  );
  final frozen = {
    for (final file in release.listSync().whereType<File>())
      file.path: sha256.convert(file.readAsBytesSync()).toString(),
  };
  final snapshot = await Process.run(args[2], [
    '--snapshot-kind=app-aot-elf',
    '--elf=${output.path}/baseline.so',
    '${release.path}/baseline.aot.dill',
  ]);
  if (snapshot.exitCode != 0) throw StateError('${snapshot.stderr}');
  final results = <String, Object>{};
  Future<void> check(
    String name,
    String updated, {
    String updatedPrice = price,
    String? rejection,
  }) async {
    mainFile.writeAsStringSync(updated);
    priceFile.writeAsStringSync(updatedPrice);
    final patch = Directory('${output.path}/$name');
    try {
      await compiler.compilePatch(
        sdk: Directory(args[0]).absolute,
        release: release,
        updatedUri: mainFile.uri,
        output: patch,
        platformDillUri: platform,
        packagesFileUri: File(args[3]).absolute.uri,
        genSnapshotUri: File(args[2]).absolute.uri,
      );
      if (rejection != null) throw StateError('Accepted unsupported $name');
      if (!File('${patch.path}/patch.bytecode').existsSync())
        throw StateError('Missing bytecode');
      results[name] = {
        'result': 'compiled',
        'metadata': jsonDecode(
          File('${patch.path}/metadata.json').readAsStringSync(),
        ),
      };
    } on FormatException catch (error) {
      if (rejection == null || !error.message.toString().contains(rejection))
        rethrow;
      if (File('${patch.path}/patch.bytecode').existsSync())
        throw StateError('Rejected input left bytecode');
      results[name] = {'result': 'rejected', 'reason': error.message};
    }
    for (final item in frozen.entries) {
      if (sha256.convert(File(item.key).readAsBytesSync()).toString() !=
          item.value) {
        throw StateError('Frozen release modified by $name');
      }
    }
    print('PASS: $name');
  }

  await check(
    'widget-title',
    source.replaceFirst("Badge('baseline')", "Badge('repaired')"),
  );
  await check(
    'widget-layout',
    source
        .replaceFirst('body: Badge', 'body: Center(child: Badge')
        .replaceFirst("Badge('baseline'))", "Badge('baseline')))"),
  );
  await check(
    'nested-constants',
    source.replaceAll("Badge('baseline')", "Badge('nested repair')"),
  );
  await check(
    'branch',
    source.replaceFirst("valid ? 'valid'", "valid ? 'accepted'"),
  );
  await check(
    'async',
    source.replaceFirst('async => total(amount)', 'async => total(amount) + 1'),
  );
  await check(
    'closure',
    source.replaceFirst('total(value)', 'total(value) + 1'),
  );
  await check(
    'cross-file',
    source.replaceFirst('=> price(amount)', '=> price(amount) + 1'),
    updatedPrice: price.replaceFirst('* 2', '* 3'),
  );
  await check(
    'field-layout',
    source.replaceFirst(
      'final String label;',
      'final String label;\n  final int added = 1;',
    ),
    rejection: 'field',
  );
  await check(
    'signature',
    source.replaceFirst(
      'int total(int amount)',
      'int total(int amount, [int extra = 0])',
    ),
    rejection: 'FunctionNode.positionalParameters',
  );
  await check(
    'new-library-reference',
    "import 'dart:math' as math;\n${source.replaceFirst('=> price(amount)', '=> math.min(price(amount), 10)')}",
    rejection: 'dependencies.length',
  );
  mainFile.writeAsStringSync(source);
  priceFile.writeAsStringSync(price);
  File(
    '${output.path}/results.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
  print(
    'PASS: Flutter compatibility matrix; baseline unchanged; ${results.length} cases',
  );
}
