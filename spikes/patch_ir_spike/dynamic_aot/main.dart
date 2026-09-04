import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dynamic_modules/dynamic_modules.dart';

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

Future<bool> installPatch(String manifestPath, String modulePath) async {
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
    installPatches(await loadModuleFromBytes(bytes));
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> main() async {
  final pricing = Pricing();
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

  if (await installPatch('bad-manifest.json', 'modules/patch.dart.bytecode')) {
    throw StateError('mismatched manifest was accepted');
  }
  if (await installPatch('manifest.json', 'modules/tampered.bytecode')) {
    throw StateError('tampered bytecode was accepted');
  }
  if (pricing.quote(3) != 4) throw StateError('failed patch changed baseline');
  if (!await installPatch('manifest.json', 'modules/patch.dart.bytecode')) {
    throw StateError('valid patch was rejected');
  }

  if (pricing.quote(3) != 37) throw StateError('patched dispatch failed');
  print(
    'PASS: identity/digest fail-open + FunctionId AOT -> interpreted closure -> baseline AOT',
  );
}
