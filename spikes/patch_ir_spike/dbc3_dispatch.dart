import 'dart:convert';
import 'dart:io';

import 'package:dynamic_modules/dynamic_modules.dart';

import 'dynamic_aot/release_identity.dart' show releaseIdentity;
import 'fixtures/patch_hook.dart' as hook;
import 'signed_manifest.dart';
import 'signed_patch_loader.dart';

typedef PatchFunction = Object? Function(Object? receiver, List<Object?> args);

// Populated in Kernel before AOT compilation, independently of the candidate.
String baselinePatchIds = '';
String baselineBuildId = '';
Map<String, PatchFunction> _active = const {};
late SignedPatchLoader _loader;

Future<LoadedPatch<void>?> bootSignedModule(List<String> paths) async {
  if (paths.length != 3)
    throw ArgumentError('module, manifest, store required');
  _loader = SignedPatchLoader(
    root: Directory(paths[2]),
    verifier: SignedManifestVerifier(
      baselineId: baselineBuildId,
      releaseIdentity: releaseIdentity,
      publicKeys: {
        'spike-p256-1': base64.decode(
          const String.fromEnvironment('HOTFIX_TEST_PUBLIC_KEY'),
        ),
      },
    ),
  );
  _loader.stage(paths[1], paths[0]);
  return _loader.load<void>((bytes) async {
    activateModule(await loadModuleFromBytes(bytes));
  }, restoreBaseline: deactivateModule);
}

bool commitModuleHealth(LoadedPatch<void> patch) => _loader.markHealthy(patch);

void activateModule(Object? result) {
  if (result is! Map) throw const FormatException('module table required');
  final allowed = baselinePatchIds.split(',').toSet();
  final next = <String, PatchFunction>{};
  for (final entry in result.entries) {
    if (entry.key is! String ||
        !allowed.contains(entry.key) ||
        entry.value is! PatchFunction) {
      throw const FormatException('module export does not match baseline');
    }
    next[entry.key as String] = entry.value as PatchFunction;
  }
  _active = Map.unmodifiable(next);
  hook.isPatched = _active.containsKey;
  hook.dispatch = (id, receiver, args) => _active[id]!(receiver, args);
}

void deactivateModule() {
  _active = const {};
  hook.isPatched = null;
  hook.dispatch = null;
}
