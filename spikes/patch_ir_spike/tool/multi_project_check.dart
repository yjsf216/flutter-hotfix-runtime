import 'dart:convert';
import 'dart:io';
import 'compile_dbc3_patch.dart' as compiler;

/// An unchanged real project must not produce a patch or a false incompatibility.
Future<void> main(List<String> args) async {
  if (args.length != 4)
    throw ArgumentError('SDK_SOURCE BASELINE FLUTTER_SDK GEN_SNAPSHOT');
  final base = Directory(args[1]).absolute;
  final metadata =
      jsonDecode(File('${base.path}/project.json').readAsStringSync()) as Map;
  final project = Directory(metadata['project'] as String);
  final output = Directory.systemTemp.createTempSync('multi-project-check.');
  try {
    try {
      await compiler.compilePatch(
        sdk: Directory(args[0]).absolute,
        release: Directory('${base.path}/release'),
        updatedUri: project.uri.resolve(metadata['patchLibrary'] as String),
        output: output,
        packagesFileUri: project.uri.resolve('.dart_tool/package_config.json'),
        platformDillUri: Directory(args[2]).absolute.uri.resolve(
          'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
        ),
        genSnapshotUri: File(args[3]).absolute.uri,
      );
    } on FormatException catch (error) {
      if (error.message != 'no changed functions') rethrow;
      if (File('${output.path}/patch.bytecode').existsSync())
        throw StateError('Unexpected bytecode');
      print('PASS: unchanged full project has no changed functions');
      return;
    }
    throw StateError('Unchanged project emitted a patch');
  } finally {
    output.deleteSync(recursive: true);
  }
}
