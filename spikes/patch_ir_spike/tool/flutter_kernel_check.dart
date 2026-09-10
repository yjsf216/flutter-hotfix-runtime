import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart2bytecode/bytecode_serialization.dart';
import 'package:dart2bytecode/declarations.dart' as bytecode;
import 'package:kernel/kernel.dart';

import 'compile_dbc3_patch.dart' as compiler;

/// Real Flutter frontend/DBC3 artifact check. Engine execution is a separate gate.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 3 && arguments.length != 4) {
    throw ArgumentError(
      'usage: flutter_kernel_check sdk-source flutter-sdk output [gen-snapshot]',
    );
  }
  final sdk = Directory(arguments[0]).absolute;
  final flutter = Directory(arguments[1]).absolute;
  final genSnapshot = File(
    arguments.length == 4
        ? arguments[3]
        : '${sdk.path}/xcodebuild/ReleaseARM64/gen_snapshot_product',
  ).absolute;
  if (!genSnapshot.existsSync()) {
    throw StateError('selected gen_snapshot missing: ${genSnapshot.path}');
  }
  final output = Directory(arguments[2]).absolute..createSync(recursive: true);
  final spike = File.fromUri(Platform.script).parent.parent;
  final fixture = Directory('${spike.path}/fixtures/flutter_compiled');
  final platform = File(
    '${flutter.path}/bin/cache/artifacts/engine/common/'
    'flutter_patched_sdk_product/platform_strong.dill',
  );
  if (!platform.existsSync())
    throw StateError('Flutter product platform missing');

  // Reuse the already resolved Flutter and runtime packages without pub get or
  // changing either app's dependencies. Preserve Flutter's shared package pins.
  final packages = <String, Map<String, Object?>>{};
  for (final path in [
    '${spike.path}/.dart_tool/package_config.json',
    '${spike.parent.path}/android_spike/.dart_tool/package_config.json',
  ]) {
    final file = File(path);
    final config = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    for (final value in config['packages'] as List) {
      final entry = Map<String, Object?>.from(value as Map);
      entry['rootUri'] = file.uri
          .resolve(entry['rootUri'] as String)
          .toString();
      packages[entry['name'] as String] = entry;
    }
  }
  final packagesFile = File('${output.path}/package_config.json')
    ..writeAsStringSync(
      jsonEncode({'configVersion': 2, 'packages': packages.values.toList()}),
    );
  final release = Directory('${output.path}/release');
  final patch = Directory('${output.path}/patch');
  await compiler.compileBaseline(
    sdk: sdk,
    baselineUri: fixture.uri.resolve('baseline.dart'),
    entryUri: fixture.uri.resolve('main.dart'),
    output: release,
    targetName: 'flutter',
    platformDillUri: platform.uri,
    packagesFileUri: packagesFile.uri,
    genSnapshotUri: genSnapshot.uri,
    retainedLibraries: {
      Uri.parse('dart:ui'),
      Uri.parse('package:flutter/src/widgets/framework.dart'),
      Uri.parse('package:flutter/src/widgets/text.dart'),
    },
  );
  final frozenFiles = {
    for (final file in release.listSync().whereType<File>())
      file.path: sha256.convert(file.readAsBytesSync()).toString(),
  };
  final snapshot = File('${output.path}/baseline.snapshot');
  final aotBuild = await Process.run(
    genSnapshot.path,
    [
      '--snapshot-kind=app-aot-elf',
      '--elf=${snapshot.path}',
      '${release.path}/baseline.aot.dill',
    ],
  );
  _require(
    aotBuild.exitCode == 0,
    'Flutter AOT snapshot compilation failed: ${aotBuild.stderr}',
  );
  await compiler.compilePatch(
    sdk: sdk,
    release: release,
    updatedUri: fixture.uri.resolve('updated.dart'),
    output: patch,
    platformDillUri: platform.uri,
    packagesFileUri: packagesFile.uri,
    genSnapshotUri: genSnapshot.uri,
  );
  for (final entry in frozenFiles.entries) {
    _require(
      sha256.convert(File(entry.key).readAsBytesSync()).toString() ==
          entry.value,
      'patch compilation changed frozen release: ${entry.key}',
    );
  }
  final baseline = loadComponentFromBinary(
    '${release.path}/baseline.input.dill',
  );
  final aot = loadComponentFromBinary('${release.path}/baseline.aot.dill');
  final library = baseline.libraries.singleWhere(
    (library) => library.fileUri == fixture.uri.resolve('baseline.dart'),
  );
  final greeting = library.classes.singleWhere(
    (cls) => cls.name == 'HotfixGreeting',
  );
  _require(
    greeting.superclass?.name == 'StatelessWidget' &&
        greeting.superclass?.enclosingLibrary.importUri.toString() ==
            'package:flutter/src/widgets/framework.dart',
    'fixture did not compile against the real Flutter Framework',
  );
  final framework = aot.libraries.singleWhere(
    (library) =>
        library.importUri.toString() == 'package:flutter/src/widgets/text.dart',
  );
  final text = framework.classes.singleWhere((cls) => cls.name == 'Text');
  _require(
    text.constructors.isNotEmpty,
    'Text constructor absent from baseline AOT',
  );
  _require(
    baseline.libraries.any(
      (library) => library.importUri.toString() == 'dart:ui',
    ),
    'Flutter dart:ui platform missing',
  );
  final bytes = File('${patch.path}/patch.bytecode').readAsBytesSync();
  final module = bytecode.Component.read(BufferedReader(LinkReader(), bytes));
  _require(
    module.libraries.length == 1 &&
        module.libraries.single.importUri.toString().contains('hotfix:patch/'),
    'patch contains libraries other than the generated module',
  );
  final dump = module.toString();
  _require(dump.contains('Text'), 'patch does not reference Flutter Text');
  _require(
    dump.contains('label'),
    'patch does not call unchanged baseline helper',
  );
  _require(dump.contains('patched'), 'updated Widget text missing from patch');
  File('${output.path}/patch.disassembly.txt').writeAsStringSync(dump);
  final metadata =
      jsonDecode(File('${patch.path}/metadata.json').readAsStringSync())
          as Map<String, dynamic>;
  _require(
    (metadata['changed'] as List).length == 1,
    'expected one changed build method',
  );
  _require(
    (metadata['newHelpers'] as List).isEmpty,
    'unexpected generated helper',
  );
  File('${output.path}/flutter-evidence.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'target': 'flutter',
      'genSnapshotPath': genSnapshot.path,
      'genSnapshotSha256': (await sha256.bind(genSnapshot.openRead()).first)
          .toString(),
      'platform': platform.path,
      'platformSha256': sha256.convert(platform.readAsBytesSync()).toString(),
      'baselineFlutterLibraries': baseline.libraries
          .where(
            (library) =>
                library.importUri.toString().startsWith('package:flutter/'),
          )
          .length,
      'patchBytes': bytes.length,
      'patchDeclaredLibraries': module.libraries
          .map((library) => '${library.importUri}')
          .toList(),
      'changedFunctions': metadata['changed'],
      'baselineUnchanged': true,
      'aotSnapshotBytes': snapshot.lengthSync(),
      'aotSnapshotSha256': sha256
          .convert(snapshot.readAsBytesSync())
          .toString(),
      'flutterEngineExecutionVerified': false,
    }),
  );
  print(
    'PASS: real Flutter target + dart:ui -> one Widget.build DBC3 patch; '
    'Framework retained in compiled AOT snapshot; frozen release unchanged',
  );
  print(
    'UNVERIFIED: Flutter Engine runtime loading/rendering and target-platform execution',
  );
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}
