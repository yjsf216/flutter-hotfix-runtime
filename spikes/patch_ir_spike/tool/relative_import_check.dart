import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'compile_dbc3_patch.dart' as compiler;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) throw ArgumentError('Dart SDK source required');
  final sdk = Directory(arguments.single).absolute;
  final spike = File.fromUri(Platform.script).parent.parent;
  final temporary = Directory.systemTemp.createTempSync('relative-import-');
  final root = Directory(temporary.resolveSymbolicLinksSync());
  try {
    for (final usePackage in [false, true]) {
      final name = usePackage ? 'package' : 'file';
      final directory = Directory('${root.path}/$name')..createSync();
      final source = Directory('${directory.path}/lib/src')
        ..createSync(recursive: true);
      final local = File('${source.path}/local.dart')
        ..writeAsStringSync('int localValue() => 1;');
      final shared = File('${directory.path}/lib/shared.dart')
        ..writeAsStringSync('int sharedValue() => 2;');
      final business = File('${source.path}/business.dart')
        ..writeAsStringSync(_business(0));
      final packagesSource = File(
        '${spike.path}/.dart_tool/package_config.json',
      );
      final packageConfig =
          jsonDecode(packagesSource.readAsStringSync()) as Map;
      final packages = File('${directory.path}/package_config.json')
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              for (final entry in packageConfig['packages'] as List)
                {
                  ...entry as Map,
                  'rootUri': packagesSource.uri
                      .resolve(entry['rootUri'] as String)
                      .toString(),
                },
              if (usePackage)
                {
                  'name': 'import_case',
                  'rootUri': directory.uri.toString(),
                  'packageUri': 'lib/',
                  'languageVersion': '3.11',
                },
            ],
          }),
        );
      final libraryUri = usePackage
          ? Uri.parse('package:import_case/src/business.dart')
          : business.uri;
      final entry = File('${directory.path}/main.dart')
        ..writeAsStringSync('''
import 'dart:io';
import 'package:dynamic_modules/dynamic_modules.dart';
import '${spike.uri.resolve('dbc3_dispatch.dart')}' as runtime;
import '$libraryUri';

Future<void> main(List<String> arguments) async {
  final service = Service();
  if (service.value() != 3) throw StateError('baseline result');
  runtime.activateModule(await loadModuleFromBytes(File(arguments.single).readAsBytesSync()));
  if (service.value() != 13) throw StateError('patch did not reuse frozen dependency AOT');
  print('PASS: $name relative imports -> frozen dependency AOT');
}
''');
      final release = Directory('${directory.path}/release');
      await compiler.compileBaseline(
        sdk: sdk,
        baselineUri: business.uri,
        entryUri: entry.uri,
        output: release,
        packagesFileUri: packages.uri,
        retainedLibraries: {
          libraryUri.resolve('local.dart'),
          libraryUri.resolve('../shared.dart'),
        },
      );
      final frozen = {
        for (final file in release.listSync().whereType<File>())
          file.path: sha256.convert(file.readAsBytesSync()).toString(),
      };
      // Replace the selected source in place. Dependency sources deliberately
      // disagree with the release, so executing 13 proves frozen AOT reuse.
      business.writeAsStringSync(_business(10));
      local.writeAsStringSync('int localValue() => 100;');
      shared.writeAsStringSync('int sharedValue() => 200;');
      final patch = Directory('${directory.path}/patch');
      await compiler.compilePatch(
        sdk: sdk,
        release: release,
        updatedUri: business.uri,
        output: patch,
        packagesFileUri: packages.uri,
      );
      for (final file in frozen.entries) {
        if (sha256.convert(File(file.key).readAsBytesSync()).toString() !=
            file.value) {
          throw StateError('frozen release changed: ${file.key}');
        }
      }
      final snapshot = '${directory.path}/baseline.snapshot';
      await _run('${sdk.path}/xcodebuild/ReleaseARM64/gen_snapshot_product', [
        '--snapshot-kind=app-aot-elf',
        '--elf=$snapshot',
        '${release.path}/baseline.aot.dill',
      ]);
      await _run('${sdk.path}/xcodebuild/ReleaseARM64/dartaotruntime_product', [
        snapshot,
        '${patch.path}/patch.bytecode',
      ]);
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

String _business(int extra) =>
    '''
import 'local.dart';
import '../shared.dart';
class Service { int value() => localValue() + sharedValue() + $extra; }
''';

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0)
    throw StateError('${result.stdout}\n${result.stderr}');
  stdout.write(result.stdout);
}
