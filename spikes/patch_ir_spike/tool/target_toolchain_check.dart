import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'compile_dbc3_patch.dart' as compiler;

/// Checks compiler identity selection using existing host binaries as data.
/// No gen_snapshot executable or platform-native artifact is executed here.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) throw ArgumentError('Dart SDK source required');
  final sdk = Directory(arguments.single).absolute;
  final spike = File.fromUri(Platform.script).parent.parent;
  final product = File(
    '${sdk.path}/xcodebuild/ReleaseARM64/gen_snapshot_product',
  );
  final other = File('${sdk.path}/xcodebuild/ReleaseARM64/gen_snapshot');
  final productHash = await _digest(product);
  final otherHash = await _digest(other);
  if (productHash == otherHash) {
    throw StateError('negative fixture requires different existing binaries');
  }
  final temporary = Directory.systemTemp.createTempSync('target-toolchain-');
  final root = Directory(temporary.resolveSymbolicLinksSync());
  try {
    final copyA = product.copySync('${root.path}/gen-snapshot-a');
    final copyB = product.copySync('${root.path}/gen-snapshot-b');
    if (await _digest(copyA) != productHash ||
        await _digest(copyB) != productHash) {
      throw StateError('binary copies changed contents');
    }
    final baseline = spike.uri.resolve('fixtures/baseline.dart');
    final updated = spike.uri.resolve('fixtures/updated.dart');
    final entry = spike.uri.resolve('fixtures/compiled_entry.dart');
    Future<void> freeze(Directory release, Uri binary) =>
        compiler.compileBaseline(
          sdk: sdk,
          baselineUri: baseline,
          entryUri: entry,
          output: release,
          genSnapshotUri: binary,
        );
    final releaseA = Directory('${root.path}/release-a');
    final releaseB = Directory('${root.path}/release-b');
    await freeze(releaseA, copyA.uri);
    await freeze(releaseB, copyB.uri);
    final descriptorA = _descriptor(releaseA);
    final descriptorB = _descriptor(releaseB);
    final recipeA = descriptorA['buildRecipe'] as Map;
    final recipeB = descriptorB['buildRecipe'] as Map;
    if (descriptorA['baselineId'] != descriptorB['baselineId'] ||
        recipeA['genSnapshotSha256'] != productHash ||
        recipeB['genSnapshotSha256'] != productHash ||
        jsonEncode(recipeA).contains(root.path) ||
        jsonEncode(recipeB).contains(root.path)) {
      throw StateError(
        'tool fingerprint depends on binary path instead of bytes',
      );
    }
    final frozenA = await _hashes(releaseA);
    final frozenB = await _hashes(releaseB);
    print(
      'PASS: identical gen_snapshot bytes at different paths freeze the same baselineId',
    );

    final explicit = Directory('${root.path}/patch-copy');
    await compiler.compilePatch(
      sdk: sdk,
      release: releaseA,
      updatedUri: updated,
      output: explicit,
      genSnapshotUri: copyB.uri,
    );
    final defaultOutput = Directory('${root.path}/patch-default');
    await compiler.compilePatch(
      sdk: sdk,
      release: releaseA,
      updatedUri: updated,
      output: defaultOutput,
    );
    for (final output in [explicit, defaultOutput]) {
      final metadata =
          jsonDecode(File('${output.path}/metadata.json').readAsStringSync())
              as Map;
      if (metadata['baselineId'] != descriptorA['baselineId'] ||
          await _digest(File('${output.path}/patch.bytecode')) !=
              metadata['artifactSha256'] ||
          File('${output.path}/baseline.aot.dill').existsSync()) {
        throw StateError(
          'selected tool did not produce a patch for the frozen baseline',
        );
      }
    }
    await _unchanged(releaseA, frozenA);
    await _unchanged(releaseB, frozenB);
    print(
      'PASS: equivalent explicit/default binary selection compiles patches without changing frozen releases',
    );

    final wrongOutput = Directory('${root.path}/wrong-binary');
    await _reject(
      () => compiler.compilePatch(
        sdk: sdk,
        release: releaseA,
        updatedUri: updated,
        output: wrongOutput,
        genSnapshotUri: other.uri,
      ),
      wrongOutput,
      'different binary',
      _toolMismatch,
    );
    final missing = File('${root.path}/missing-gen-snapshot');
    final missingOutput = Directory('${root.path}/missing-binary');
    await _reject(
      () => compiler.compilePatch(
        sdk: sdk,
        release: releaseA,
        updatedUri: updated,
        output: missingOutput,
        genSnapshotUri: missing.uri,
      ),
      missingOutput,
      'explicit missing binary',
      (error) => error is FileSystemException && error.path == missing.path,
    );
    await _unchanged(releaseA, frozenA);

    // A different real host binary can be fingerprinted as its own release.
    // This is not evidence that it can compile or run a target-platform AOT.
    final alternate = Directory('${root.path}/release-alternate');
    await freeze(alternate, other.uri);
    final alternateDescriptor = _descriptor(alternate);
    if ((alternateDescriptor['buildRecipe'] as Map)['genSnapshotSha256'] !=
            otherHash ||
        alternateDescriptor['baselineId'] == descriptorA['baselineId']) {
      throw StateError(
        'explicit alternate tool was silently replaced by the host default',
      );
    }
    final frozenAlternate = await _hashes(alternate);
    final fallbackOutput = Directory('${root.path}/forbidden-default-fallback');
    await _reject(
      () => compiler.compilePatch(
        sdk: sdk,
        release: alternate,
        updatedUri: updated,
        output: fallbackOutput,
      ),
      fallbackOutput,
      'omitted override on an alternate-tool release',
      _toolMismatch,
    );
    await _unchanged(alternate, frozenAlternate);
    await _unchanged(releaseA, frozenA);
    await _unchanged(releaseB, frozenB);
    print(
      'PASS: explicit alternate fingerprint is retained and incompatible default fallback is rejected',
    );
    print(
      'SCOPE: compiler/toolchain identity only; no native binary or Android/iOS/OHOS artifact executed',
    );
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

Map<String, dynamic> _descriptor(Directory release) =>
    jsonDecode(File('${release.path}/release.json').readAsStringSync())
        as Map<String, dynamic>;

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<Map<String, String>> _hashes(Directory directory) async {
  final files =
      directory
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return {
    for (final file in files)
      file.path.substring(directory.path.length + 1): await _digest(file),
  };
}

Future<void> _unchanged(Directory release, Map<String, String> frozen) async {
  if (jsonEncode(await _hashes(release)) != jsonEncode(frozen)) {
    throw StateError('frozen release files changed: ${release.path}');
  }
}

bool _toolMismatch(Object error) =>
    error is FormatException &&
    error.message.contains(
      'frozen compiler/toolchain mismatch: genSnapshotSha256',
    );

Future<void> _reject(
  Future<void> Function() operation,
  Directory output,
  String name,
  bool Function(Object) expected,
) async {
  var refused = false;
  try {
    await operation();
  } on Object catch (error) {
    if (!expected(error)) rethrow;
    refused = true;
  }
  if (!refused || (output.existsSync() && output.listSync().isNotEmpty)) {
    throw StateError('$name was not rejected before patch output');
  }
  print('PASS: $name rejected before patch output');
}
