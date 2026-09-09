// Offline test signer only. No private key or process dependency enters Runtime.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../dynamic_aot/release_identity.dart';
import '../signed_manifest.dart';

const _keyId = 'spike-p256-1';

void main(List<String> args) {
  if (args.length == 2 && args[0] == 'keygen') {
    _keygen(Directory(args[1]));
  } else if ((args.length >= 4 && args.length <= 6) && args[0] == 'sign') {
    final directory = Directory(args[1]);
    final artifact = File(args[2]).readAsBytesSync();
    final manifest = _manifest(artifact, DateTime.now().toUtc());
    if (args.length >= 5) manifest['baselineId'] = args[4];
    if (args.length == 6) manifest['patchId'] = args[5];
    File(args[3]).writeAsBytesSync(_sign(directory, manifest));
  } else if (args.isEmpty) {
    _selfCheck();
  } else {
    throw ArgumentError(
      'usage: signature_check.dart [keygen DIR | sign DIR ARTIFACT MANIFEST [BASELINE_ID [PATCH_ID]]]',
    );
  }
}

void _openssl(List<String> args) {
  final result = Process.runSync('openssl', args);
  if (result.exitCode != 0) {
    throw StateError('OpenSSL ${args.first} failed: ${result.stderr}');
  }
}

void _keygen(Directory directory) {
  directory.createSync(recursive: true);
  _openssl([
    'ecparam',
    '-name',
    'prime256v1',
    '-genkey',
    '-noout',
    '-out',
    '${directory.path}/private.pem',
  ]);
  _openssl([
    'ec',
    '-in',
    '${directory.path}/private.pem',
    '-pubout',
    '-outform',
    'DER',
    '-out',
    '${directory.path}/public.der',
  ]);
  final der = File('${directory.path}/public.der').readAsBytesSync();
  final prefix = der
      .take(26)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  if (der.length != 91 ||
      prefix != '3059301306072a8648ce3d020106082a8648ce3d030107034200') {
    throw StateError('OpenSSL did not produce the expected P-256 SPKI');
  }
  File(
    '${directory.path}/public-key.txt',
  ).writeAsStringSync(base64.encode(der.sublist(26)));
}

Map<String, Object?> _manifest(Uint8List artifact, DateTime now) => {
  'schemaVersion': 1,
  'signatureAlgorithm': signatureAlgorithm,
  'keyId': _keyId,
  'baselineId': baselineId,
  'patchId': 'p1',
  'identity': releaseIdentity,
  'artifactSha256': sha256.convert(artifact).toString(),
  'artifactSize': artifact.length,
  'issuedAt': _timestamp(now.subtract(const Duration(minutes: 1))),
  'expiresAt': _timestamp(now.add(const Duration(days: 1))),
  'revoked': false,
  'rolloutPercent': 100,
};

String _timestamp(DateTime value) =>
    '${value.toUtc().toIso8601String().split('.').first}Z';

Uint8List _sign(Directory directory, Map<String, Object?> manifest) {
  final unsigned = File('${directory.path}/unsigned.json')
    ..writeAsBytesSync(canonicalManifestBytes(manifest));
  final signature = File('${directory.path}/manifest.sig');
  _openssl([
    'dgst',
    '-sha256',
    '-sign',
    '${directory.path}/private.pem',
    '-out',
    signature.path,
    unsigned.path,
  ]);
  return canonicalManifestBytes({
    'manifest': manifest,
    'signature': base64.encode(signature.readAsBytesSync()),
  });
}

void _selfCheck() {
  final temporary = Directory.systemTemp.createTempSync('hotfix-signatures-');
  try {
    _keygen(temporary);
    final publicKey = base64.decode(
      File('${temporary.path}/public-key.txt').readAsStringSync(),
    );
    final verifier = SignedManifestVerifier(
      baselineId: baselineId,
      releaseIdentity: releaseIdentity,
      publicKeys: {_keyId: publicKey},
    );
    final now = DateTime.utc(2026, 9, 9, 0, 0, 0);
    final artifact = Uint8List.fromList(
      utf8.encode('DBC3 signed test payload'),
    );
    final manifest = _manifest(artifact, now);
    final envelope = _sign(temporary, manifest);
    final verified = verifier.verify(envelope, now: now);
    if (verified == null ||
        !verified.matchesArtifact(artifact) ||
        verified.patchId != 'p1') {
      throw StateError('OpenSSL P-256 signature did not verify');
    }
    final sameLengthTamper = Uint8List.fromList(artifact)..[0] ^= 1;
    if (verified.matchesArtifact(sameLengthTamper) ||
        verified.matchesArtifact(Uint8List.fromList([...artifact, 0]))) {
      throw StateError('artifact tampering passed');
    }
    var rejected = 0;
    void rejects(Uint8List bytes, String name) {
      if (verifier.verify(bytes, now: now) != null) {
        throw StateError('$name passed verification');
      }
      rejected++;
    }

    Map<String, Object?> clone() =>
        jsonDecode(jsonEncode(manifest)) as Map<String, Object?>;
    void rejectsSigned(
      String name,
      void Function(Map<String, Object?>) mutate,
    ) {
      final changed = clone();
      mutate(changed);
      rejects(_sign(temporary, changed), name);
    }

    for (final key in releaseIdentityFields) {
      rejectsSigned('identity $key', (m) {
        final identity = m['identity'] as Map<String, Object?>;
        identity[key] = key == 'buildParametersSha256'
            ? '0' * 64
            : '${identity[key]}-wrong';
      });
    }
    rejectsSigned('baseline', (m) => m['baselineId'] = 'wrong');
    rejectsSigned('algorithm', (m) => m['signatureAlgorithm'] = 'none');
    rejectsSigned('unknown key', (m) => m['keyId'] = 'unknown');
    rejectsSigned('revoked', (m) => m['revoked'] = true);
    rejectsSigned(
      'missing identity',
      (m) => (m['identity'] as Map).remove('flavor'),
    );
    rejectsSigned(
      'extra identity',
      (m) => (m['identity'] as Map)['extra'] = 'x',
    );
    rejectsSigned('unknown field', (m) => m['unsignedOverride'] = true);
    rejectsSigned('path traversal', (m) => m['patchId'] = '../p1');
    rejectsSigned('reserved patch', (m) => m['patchId'] = 'bundled');
    rejectsSigned('empty artifact', (m) => m['artifactSize'] = 0);
    rejectsSigned(
      'oversized artifact',
      (m) => m['artifactSize'] = maxArtifactBytes + 1,
    );
    rejectsSigned('malformed hash', (m) => m['artifactSha256'] = 'F' * 64);
    rejectsSigned('expired', (m) => m['expiresAt'] = _timestamp(now));
    rejectsSigned(
      'future',
      (m) => m['issuedAt'] = _timestamp(now.add(const Duration(hours: 1))),
    );
    rejectsSigned(
      'invalid date',
      (m) => m['issuedAt'] = '2026-08-32T00:00:00Z',
    );
    rejectsSigned('rollout', (m) => m['rolloutPercent'] = 101);
    final decoded = jsonDecode(utf8.decode(envelope)) as Map<String, Object?>;
    final badSignature = base64.decode(decoded['signature'] as String)
      ..[10] ^= 1;
    rejects(
      canonicalManifestBytes({
        ...decoded,
        'signature': base64.encode(badSignature),
      }),
      'forged signature',
    );
    final badHash = clone()
      ..['artifactSha256'] = sha256.convert(sameLengthTamper).toString();
    rejects(
      canonicalManifestBytes({...decoded, 'manifest': badHash}),
      'unsigned artifact+hash substitution',
    );
    final text = utf8.decode(envelope);
    rejects(Uint8List.fromList(utf8.encode('$text\n')), 'trailing whitespace');
    rejects(
      Uint8List.fromList(
        utf8.encode(
          text.replaceFirst('"patchId":"p1"', '"patchId":"p1","patchId":"p1"'),
        ),
      ),
      'duplicate key',
    );
    rejects(
      Uint8List.fromList(
        utf8.encode(
          text.replaceFirst('"schemaVersion":1', '"schemaVersion":1.0'),
        ),
      ),
      'floating point',
    );
    rejects(
      Uint8List.fromList(
        utf8.encode(
          text.replaceFirst('"schemaVersion":1', '"schemaVersion":1e0'),
        ),
      ),
      'number exponent',
    );
    rejects(Uint8List.fromList([0xef, 0xbb, 0xbf, ...envelope]), 'BOM');
    rejects(Uint8List.fromList([0xff, ...envelope]), 'malformed UTF-8');
    rejects(Uint8List.fromList(utf8.encode('[[[[[0]]]]]')), 'depth limit');
    rejects(Uint8List(maxManifestBytes + 1), 'size limit');
    rejects(
      canonicalManifestBytes({
        ...decoded,
        'signature': '${decoded['signature']}=',
      }),
      'base64 alias',
    );
    for (final signature in [
      <int>[],
      [0x30, 6, 2, 1, 0, 2, 1, 0], // Zero integers are out of range.
      [0x30, 7, 2, 2, 0, 1, 2, 1, 1], // Redundant integer leading zero.
      [0x30, 6, 2, 1, 128, 2, 1, 1], // Negative integer.
      [0x30, 0x81, 6, 2, 1, 1, 2, 1, 1], // Long-form length.
      [...base64.decode(decoded['signature'] as String), 0], // Trailing data.
    ]) {
      rejects(
        canonicalManifestBytes({
          ...decoded,
          'signature': base64.encode(signature),
        }),
        'malformed DER',
      );
    }
    final revokedVerifier = SignedManifestVerifier(
      baselineId: baselineId,
      releaseIdentity: releaseIdentity,
      publicKeys: {_keyId: publicKey},
      revokedKeyIds: {_keyId},
    );
    if (revokedVerifier.verify(envelope, now: now) != null) {
      throw StateError('revoked embedded key passed');
    }
    final secondKey = Directory('${temporary.path}/second');
    _keygen(secondKey);
    final wrongVerifier = SignedManifestVerifier(
      baselineId: baselineId,
      releaseIdentity: releaseIdentity,
      publicKeys: {
        _keyId: base64.decode(
          File('${secondKey.path}/public-key.txt').readAsStringSync(),
        ),
      },
    );
    if (wrongVerifier.verify(envelope, now: now) != null) {
      throw StateError('wrong embedded key passed');
    }
    print(
      'PASS: OpenSSL P-256 -> pure Dart verifier; $rejected malformed/tampered/binding cases rejected; revoked/wrong key rejected',
    );
  } finally {
    temporary.deleteSync(recursive: true);
  }
}
