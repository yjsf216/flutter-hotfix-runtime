import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dynamic_modules/dynamic_modules.dart';

import 'dynamic_aot/release_identity.dart' show releaseIdentity;
import 'fixtures/patch_hook.dart' as hook;
import 'signed_manifest.dart';
import 'signed_patch_loader.dart';
import 'native_store_io.dart';
import 'update_client.dart';

typedef PatchFunction = Object? Function(Object? receiver, List<Object?> args);

// Populated in Kernel before AOT compilation, independently of the candidate.
String baselinePatchIds = '';
String baselineBuildId = '';
Map<String, Function> _active = const {};
late SignedPatchLoader _loader;

// Replaced in baseline Kernel with per-FunctionId ABI type checks. The default
// rejects every export, including otherwise callable generic functions.
bool hotfixValidatePatch(String functionId, Object? candidate) => false;

Future<LoadedPatch<void>?> bootSignedModule(List<String> paths) async {
  if (paths.length != 3)
    throw ArgumentError('module, manifest, store required');
  try {
    _loader = SignedPatchLoader(
      root: Directory(paths[2]),
      nativeIo: const bool.fromEnvironment('HOTFIX_NATIVE_STORE')
          ? Platform.environment['HOTFIX_TEST_NATIVE_LIBRARY'] == null
                ? NativeStoreIo.bundled(Directory(paths[2]))
                : NativeStoreIo(
                    Directory(paths[2]),
                    DynamicLibrary.open(
                      Platform.environment['HOTFIX_TEST_NATIVE_LIBRARY']!,
                    ),
                  )
          : null,
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
    return await _loader.load<void>((bytes) async {
      activateModule(await loadModuleFromBytes(bytes));
    }, restoreBaseline: deactivateModule);
  } on Object catch (error) {
    print('HotfixBootstrap initialization failed: $error');
    deactivateModule();
    return null;
  }
}

bool commitModuleHealth(LoadedPatch<void> patch) => _loader.markHealthy(patch);

Future<void> checkUpdatesAfterHealth(LoadedPatch<void>? patch) async {
  const origin = String.fromEnvironment('HOTFIX_UPDATE_ORIGIN');
  if (origin.isEmpty) return;
  try {
    final delivery = UpdateClient(_loader, Uri.parse(origin),
      allowDevelopmentHttp: const bool.fromEnvironment('HOTFIX_ALLOW_DEV_HTTP'));
    await delivery.report(patch == null ? 'baseline_healthy' : 'patch_healthy', patch?.patchId);
    final status = await delivery.checkAndDownload(runningPatchId: patch?.patchId);
    print('HotfixDelivery $status (takes effect on next startup)');
  } on Object catch (error) {
    print('HotfixDelivery unavailable: $error');
  }
}

void activateModule(Object? result) {
  if (result is! Map) throw const FormatException('module table required');
  final allowed = baselinePatchIds.split(',').toSet();
  final next = <String, Function>{};
  for (final entry in result.entries) {
    if (entry.key is! String ||
        !allowed.contains(entry.key) ||
        entry.value is! Function ||
        !hotfixValidatePatch(entry.key as String, entry.value)) {
      throw const FormatException('module export does not match baseline');
    }
    next[entry.key as String] = entry.value as Function;
  }
  _active = Map.unmodifiable(next);
  hook.isPatched = _active.containsKey;
  hook.dispatch = (id, receiver, args) =>
      (_active[id]! as PatchFunction)(receiver, args);
  hook.lookup = (id) => _active[id];
}

void deactivateModule() {
  _active = const {};
  hook.isPatched = null;
  hook.dispatch = null;
  hook.lookup = null;
}
