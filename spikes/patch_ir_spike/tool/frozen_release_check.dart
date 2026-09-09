import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'compile_dbc3_patch.dart' as compiler;

Future<void> main(List<String> args) async {
  if (args.length != 2)
    throw ArgumentError('SDK source and bundled native library required');
  final sdk = Directory(args[0]).absolute;
  final nativeLibrary = File(args[1]).absolute.path;
  final spike = File.fromUri(Platform.script).parent.parent;
  final temporary = Directory.systemTemp.createTempSync('frozen-release-');
  final root = Directory(temporary.resolveSymbolicLinksSync());
  Future<void> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      environment: environment,
    );
    if (result.exitCode != 0)
      throw StateError('${result.stdout}\n${result.stderr}');
  }

  try {
    final signer = '${spike.path}/tool/signature_check.dart';
    final keys = '${root.path}/keys';
    await run(Platform.resolvedExecutable, [signer, 'keygen', keys]);
    final publicKey = File('$keys/public-key.txt').readAsStringSync();
    final sources = Directory('${root.path}/source')..createSync();
    final business = File('${sources.path}/baseline.dart')
      ..writeAsStringSync(
        File('${spike.path}/fixtures/baseline.dart').readAsStringSync(),
      );
    final entry = File('${sources.path}/main.dart')
      ..writeAsStringSync(
        File(
          '${spike.path}/fixtures/compiled_entry.dart',
        ).readAsStringSync().replaceFirst(
          "'../dbc3_dispatch.dart'",
          "'${spike.uri.resolve('dbc3_dispatch.dart')}'",
        ),
      );
    final release = Directory('${root.path}/release');
    await compiler.compileBaseline(
      sdk: sdk,
      baselineUri: business.uri,
      entryUri: entry.uri,
      output: release,
      environmentDefines: {
        'HOTFIX_TEST_PUBLIC_KEY': publicKey,
        'HOTFIX_NATIVE_STORE': 'true',
      },
    );
    final snapshot = '${release.path}/baseline.snapshot';
    await run('${sdk.path}/xcodebuild/ReleaseARM64/gen_snapshot_product', [
      '--snapshot-kind=app-aot-elf',
      '--elf=$snapshot',
      '${release.path}/baseline.aot.dill',
    ]);
    final frozen = {
      for (final file in release.listSync().whereType<File>())
        file.path: sha256.convert(file.readAsBytesSync()).toString(),
    };
    // The original entry is unavailable and the baseline source is overwritten
    // in place. A patch can only succeed by importing the frozen Kernel.
    entry.renameSync('${entry.path}.archived');
    business.writeAsStringSync(
      File('${spike.path}/fixtures/updated.dart').readAsStringSync(),
    );
    final patch = Directory('${root.path}/patch');
    await compiler.compilePatch(
      sdk: sdk,
      release: release,
      updatedUri: business.uri,
      output: patch,
    );
    for (final file in frozen.entries) {
      if (sha256.convert(File(file.key).readAsBytesSync()).toString() !=
          file.value) {
        throw StateError('patch rewrote frozen release: ${file.key}');
      }
    }
    if (File('${patch.path}/baseline.aot.dill').existsSync())
      throw StateError('patch emitted replacement AOT');
    final baselineId = File('${release.path}/baseline.id').readAsStringSync();
    await run(Platform.resolvedExecutable, [
      signer,
      'sign',
      keys,
      '${patch.path}/patch.bytecode',
      '${patch.path}/manifest.json',
      baselineId,
    ]);
    await run(
      '${sdk.path}/xcodebuild/ReleaseARM64/dartaotruntime_product',
      [
        snapshot,
        '${patch.path}/patch.bytecode',
        '${patch.path}/manifest.json',
        '${root.path}/store',
      ],
      environment: {'HOTFIX_TEST_NATIVE_LIBRARY': nativeLibrary},
    );
    print(
      'PASS: patch after in-place source replacement and entry removal; frozen AOT/metadata unchanged',
    );

    final input = File('${release.path}/baseline.input.dill');
    final original = input.readAsBytesSync();
    input.writeAsBytesSync([
      ...original.take(original.length - 1),
      original.last ^ 1,
    ]);
    var rejected = false;
    try {
      await compiler.compilePatch(
        sdk: sdk,
        release: release,
        updatedUri: business.uri,
        output: Directory('${root.path}/rejected'),
      );
    } on FormatException catch (error) {
      rejected = error.message.contains('frozen baseline identity mismatch');
    }
    if (!rejected || File('${root.path}/rejected/patch.bytecode').existsSync())
      throw StateError('corrupted baseline accepted');
    input.writeAsBytesSync(original);
    final descriptor = File('${release.path}/release.json');
    final metadata =
        jsonDecode(descriptor.readAsStringSync()) as Map<String, dynamic>;
    final recipe = metadata['buildRecipe'] as Map<String, dynamic>;
    recipe['genSnapshotSha256'] = '0' * 64;
    final forgedId = sha256.convert(utf8.encode(jsonEncode(recipe))).toString();
    metadata['baselineId'] = forgedId;
    descriptor.writeAsStringSync(jsonEncode(metadata));
    File('${release.path}/baseline.id').writeAsStringSync(forgedId);
    rejected = false;
    try {
      await compiler.compilePatch(
        sdk: sdk,
        release: release,
        updatedUri: business.uri,
        output: Directory('${root.path}/wrong-compiler'),
      );
    } on FormatException catch (error) {
      rejected = error.message.contains('frozen compiler/toolchain mismatch');
    }
    if (!rejected) throw StateError('wrong AOT toolchain accepted');
    print(
      'PASS: corrupted frozen Kernel and mismatched AOT compiler rejected before patch emission',
    );
  } finally {
    temporary.deleteSync(recursive: true);
  }
}
