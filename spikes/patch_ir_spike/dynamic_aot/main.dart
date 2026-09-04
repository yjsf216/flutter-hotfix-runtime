import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dynamic_modules/dynamic_modules.dart';

import '../patch_store.dart';
import 'runtime_api.dart';

const baselineId = 'dbc3-host-baseline-v1';
const releaseIdentity = <String, Object?>{
  'appId': 'dev.hotfixruntime.fixture',
  'platform': 'host',
  'abi': 'arm64',
  'release': '1.0.0+1',
  'dartVersion': '3.11.5',
  'engineRevision': '42d3d75a56efe1a2e9902f52dc8006099c45d937',
};

Future<bool> stagePatch(
  PatchStore store,
  String manifestPath,
  String modulePath,
) async {
  try {
    final manifest = jsonDecode(File(manifestPath).readAsStringSync()) as Map;
    // ponytail: test token; platform P-256 verifier owns production signature checks.
    if (manifest['signature'] != 'valid-signature' ||
        manifest['baselineId'] != baselineId) {
      return false;
    }
    final identity = manifest['identity'];
    if (identity is! Map ||
        identity.length != releaseIdentity.length ||
        releaseIdentity.entries.any(
          (entry) => identity[entry.key] != entry.value,
        )) {
      return false;
    }
    final bytes = File(modulePath).readAsBytesSync();
    if (manifest['irLength'] != bytes.length ||
        manifest['irSha256'] != sha256.convert(bytes).toString()) {
      return false;
    }
    final patchId = manifest['patchId'];
    return patchId is String &&
        store.install(patchId, bytes, manifest['irSha256'] as String);
  } catch (_) {
    return false;
  }
}

Future<void> main() async {
  final pricing = Pricing();
  final storeRoot = Directory('patch-store');
  final store = PatchStore(storeRoot);
  if (pricing.quote(3) != 4) throw StateError('baseline dispatch failed');

  var rejected = false;
  try {
    installPatches(<String, PatchBody>{
      Pricing.quoteId: (_) => 99,
      'unknown': (_) => 100,
    });
  } on StateError {
    rejected = true;
  }
  if (!rejected) throw StateError('invalid table was accepted');
  if (pricing.quote(3) != 4) {
    throw StateError('invalid table was partially installed');
  }

  if (await stagePatch(
    store,
    'bad-manifest.json',
    'modules/patch.dart.bytecode',
  )) {
    throw StateError('mismatched manifest was accepted');
  }
  if (await stagePatch(store, 'manifest.json', 'modules/tampered.bytecode')) {
    throw StateError('tampered bytecode was accepted');
  }
  if (pricing.quote(3) != 4) throw StateError('failed patch changed baseline');
  if (!await stagePatch(
    store,
    'manifest.json',
    'modules/patch.dart.bytecode',
  )) {
    throw StateError('valid patch was rejected');
  }

  File('${storeRoot.path}/versions/p1.ir').writeAsStringSync('disk-tamper');
  if (store.beginBoot() != PatchStore.bundled || pricing.quote(3) != 4) {
    throw StateError('stored tamper did not fall back to baseline');
  }
  if (!await stagePatch(
    store,
    'manifest.json',
    'modules/patch.dart.bytecode',
  )) {
    throw StateError('valid patch could not be restaged');
  }
  final selected = store.beginBoot();
  final selectedBytes = store.readVerified(selected);
  if (selected != 'p1' || selectedBytes == null) {
    throw StateError('stored patch was not selected');
  }
  installPatches(await loadModuleFromBytes(selectedBytes));
  if (!store.markHealthy(selected)) throw StateError('health commit failed');

  for (var i = 0; i < 20000; i++) {
    if (pricing.quote(3) != 37) throw StateError('patched dispatch failed');
  }
  var caught = false;
  try {
    pricing.fail();
  } on StateError catch (error) {
    caught = error.message == 'interpreted failure';
  }
  if (!caught) throw StateError('interpreted exception did not cross AOT');
  if (await pricing.asyncQuote(3) != 37) {
    throw StateError('interpreted async did not cross AOT');
  }
  print(
    'PASS: verified store + GC/exception/async AOT <-> interpreted closures',
  );
}
