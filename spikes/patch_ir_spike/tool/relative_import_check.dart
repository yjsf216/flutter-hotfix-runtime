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
    for (final name in ['file', 'package', 'file-parts', 'package-parts']) {
      final usePackage = name.startsWith('package');
      final withParts = name.endsWith('-parts');
      final directory = Directory('${root.path}/$name')..createSync();
      final source = Directory('${directory.path}/lib/src')
        ..createSync(recursive: true);
      final local = File('${source.path}/local.dart')
        ..writeAsStringSync('int localValue() => 1;');
      final shared = File('${directory.path}/lib/shared.dart')
        ..writeAsStringSync('int sharedValue() => 2;');
      final business = File('${source.path}/business.dart')
        ..writeAsStringSync(withParts ? _partBusiness : _business(0));
      final partDirectory = Directory('${source.path}/parts')..createSync();
      final servicePart = File('${partDirectory.path}/service.dart');
      final helperPart = File('${partDirectory.path}/helper.dart');
      if (withParts) {
        servicePart.writeAsStringSync(_servicePart(0));
        helperPart.writeAsStringSync(_helperPart(0));
      }
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
  for (var i = 0; i < arguments.length; i++) {
    runtime.activateModule(await loadModuleFromBytes(File(arguments[i]).readAsBytesSync()));
    if (service.value() != 13 + i * 10) throw StateError('patch did not reuse frozen dependency AOT');
  }
  print('PASS: $name relative imports/parts -> frozen dependency AOT');
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
      final originalRoot = sha256
          .convert(business.readAsBytesSync())
          .toString();
      // Replace the selected source in place. Dependency sources deliberately
      // disagree with the release, so executing 13 proves frozen AOT reuse.
      local.writeAsStringSync('int localValue() => 100;');
      shared.writeAsStringSync('int sharedValue() => 200;');
      final artifacts = <String>[];
      final moduleUris = <String>{};
      final sourceHashes = <String>{};
      for (var version = 1; version <= 2; version++) {
        if (withParts) {
          helperPart.writeAsStringSync(_helperPart(10, (version - 1) * 5));
          servicePart.writeAsStringSync(_servicePart((version - 1) * 5));
        } else {
          business.writeAsStringSync(_business(version * 10));
        }
        final patch = Directory('${directory.path}/patch-$version');
        await compiler.compilePatch(
          sdk: sdk,
          release: release,
          updatedUri: business.uri,
          output: patch,
          packagesFileUri: packages.uri,
        );
        artifacts.add('${patch.path}/patch.bytecode');
        final metadata =
            jsonDecode(File('${patch.path}/metadata.json').readAsStringSync())
                as Map;
        moduleUris.add((metadata['moduleLibraries'] as List).single as String);
        sourceHashes.add(metadata['sourceBundleSha256'] as String);
      }
      if (moduleUris.length != 2 || sourceHashes.length != 2) {
        throw StateError('different candidate sources reused module identity');
      }
      if (withParts &&
          sha256.convert(business.readAsBytesSync()).toString() !=
              originalRoot) {
        throw StateError('part-only fixture changed its root library');
      }
      if (withParts) {
        final repeated = Directory('${directory.path}/patch-repeat');
        await compiler.compilePatch(
          sdk: sdk,
          release: release,
          updatedUri: business.uri,
          output: repeated,
          packagesFileUri: packages.uri,
        );
        if (sha256.convert(File(artifacts.last).readAsBytesSync()).toString() !=
            sha256
                .convert(
                  File('${repeated.path}/patch.bytecode').readAsBytesSync(),
                )
                .toString()) {
          throw StateError('unchanged part bundle produced different bytecode');
        }
      }
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
        ...artifacts,
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

const _partBusiness = '''
import 'local.dart';
import '../shared.dart';
part 'parts/service.dart';
part 'parts/helper.dart';
''';

String _servicePart(int extra) =>
    '''
part of '../business.dart';
class Service {
  int _offset = 0;
  int value() => _readPrivate(this) + _delta() + $extra;
}
''';

String _helperPart(int extra, [int readExtra = 0]) =>
    '''
part of '../business.dart';
int _readPrivate(Service service) => localValue() + sharedValue() + service._offset + $readExtra;
int _delta() => $extra;
''';

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0)
    throw StateError('${result.stdout}\n${result.stderr}');
  stdout.write(result.stdout);
}
