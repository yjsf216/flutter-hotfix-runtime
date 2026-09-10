import 'dart:io';
import 'compile_dbc3_patch.dart';

/// Patch-only command: never rebuilds or rewrites the frozen release.
Future<void> main(List<String> args) async {
  if (args.length != 7) {
    throw ArgumentError(
      'compile_flutter_patch.dart SDK FLUTTER GEN_SNAPSHOT RELEASE UPDATED OUTPUT PACKAGES',
    );
  }
  await compilePatch(
    sdk: Directory(args[0]).absolute,
    genSnapshotUri: File(args[2]).absolute.uri,
    release: Directory(args[3]).absolute,
    updatedUri: File(args[4]).absolute.uri,
    output: Directory(args[5]).absolute,
    platformDillUri: File(
      '${args[1]}/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
    ).absolute.uri,
    packagesFileUri: File(args[6]).absolute.uri,
  );
}
