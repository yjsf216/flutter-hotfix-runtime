import 'dart:convert';
import 'dart:io';
import '../signed_manifest.dart';
import '../dynamic_aot/release_identity.dart';

void main(List<String> args) {
  if (args.length != 2) throw ArgumentError('BASELINE PATCH_DIR required');
  final recipe =
      jsonDecode(File('${args[0]}/release/release.json').readAsStringSync())
          as Map;
  final defines = recipe['buildRecipe']['environmentDefines'] as Map;
  final verifier = SignedManifestVerifier(
    baselineId: recipe['baselineId'] as String,
    releaseIdentity: {
      ...releaseIdentity,
      'appId': defines['HOTFIX_APP_ID'],
      'platform': defines['HOTFIX_PLATFORM'],
      'release': defines['HOTFIX_RELEASE'],
    },
    publicKeys: {
      'spike-p256-1': base64.decode(
        defines['HOTFIX_TEST_PUBLIC_KEY'] as String,
      ),
    },
  );
  final verified = verifier.verify(
    File('${args[1]}/manifest.json').readAsBytesSync(),
  );
  if (verified == null ||
      !verified.matchesArtifact(
        File('${args[1]}/patch.bytecode').readAsBytesSync(),
      )) {
    throw StateError(
      'signature does not match frozen baseline; do not publish',
    );
  }
  print('PASS: signature verified against the frozen baseline');
}
