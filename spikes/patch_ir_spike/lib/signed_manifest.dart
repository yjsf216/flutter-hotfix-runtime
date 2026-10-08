import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

const signatureAlgorithm = 'ECDSA_P256_SHA256';
const maxManifestBytes = 16 * 1024;
const maxArtifactBytes = 64 * 1024 * 1024;
const releaseIdentityFields = <String>{
  'appId',
  'platform',
  'abi',
  'release',
  'flutterRevision',
  'dartVersion',
  'engineRevision',
  'flavor',
  'channel',
  'buildParametersSha256',
};
const _manifestFields = <String>{
  'schemaVersion',
  'signatureAlgorithm',
  'keyId',
  'baselineId',
  'patchId',
  'identity',
  'artifactSha256',
  'artifactSize',
  'issuedAt',
  'expiresAt',
  'revoked',
  'rolloutPercent',
};
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final _identifierPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$');

/// Schema v1 signing format, not a general-purpose RFC 8785 implementation.
/// UTF-8, recursively sorted keys, integer numbers, no whitespace or final LF.
Uint8List canonicalManifestBytes(Object? value) {
  Object? sorted(Object? node, int depth) {
    if (depth > 4) throw const FormatException('manifest too deep');
    if (node is Map<String, Object?>) {
      final keys = node.keys.toList()..sort();
      return {for (final key in keys) key: sorted(node[key], depth + 1)};
    }
    if (node is List<Object?>) {
      return [for (final item in node) sorted(item, depth + 1)];
    }
    if (node is int && node.abs() <= 9007199254740991 ||
        node == null ||
        node is bool ||
        node is String) {
      return node;
    }
    throw const FormatException('unsupported manifest value');
  }

  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(sorted(value, 0))));
  if (bytes.length > maxManifestBytes) {
    throw const FormatException('manifest too large');
  }
  return bytes;
}

/// Constructible only after authenticating the complete manifest and identity.
final class VerifiedManifest {
  VerifiedManifest._(Map<String, Object?> manifest)
    : patchId = manifest['patchId'] as String,
      baselineId = manifest['baselineId'] as String,
      artifactSha256 = manifest['artifactSha256'] as String,
      artifactSize = manifest['artifactSize'] as int,
      keyId = manifest['keyId'] as String,
      rolloutPercent = manifest['rolloutPercent'] as int,
      revoked = manifest['revoked'] as bool,
      identity = Map.unmodifiable(manifest['identity'] as Map<String, Object?>);

  final String patchId;
  final String baselineId;
  final String artifactSha256;
  final int artifactSize;
  final String keyId;
  final int rolloutPercent;
  final bool revoked;
  final Map<String, Object?> identity;

  bool matchesArtifact(Uint8List bytes) =>
      bytes.length == artifactSize &&
      sha256.convert(bytes).toString() == artifactSha256;
}

/// Trust anchors must come from the signed app build, never downloaded state.
/// Keys are 65-byte SEC1 uncompressed P-256 points (04 || X || Y).
final class SignedManifestVerifier {
  SignedManifestVerifier({
    required this.baselineId,
    required Map<String, Object?> releaseIdentity,
    required Map<String, Uint8List> publicKeys,
    Set<String> revokedKeyIds = const {},
    DateTime Function()? clock,
  }) : releaseIdentity = Map.unmodifiable(releaseIdentity),
       clock = clock ?? DateTime.now,
       _revokedKeyIds = Set.unmodifiable(revokedKeyIds) {
    if (!_identifierPattern.hasMatch(baselineId) ||
        !_validIdentity(releaseIdentity) ||
        publicKeys.isEmpty) {
      throw ArgumentError('invalid embedded release identity or trust anchors');
    }
    for (final entry in publicKeys.entries) {
      final encoded = Uint8List.fromList(entry.value);
      if (!_identifierPattern.hasMatch(entry.key) ||
          encoded.length != 65 ||
          encoded.first != 4) {
        throw ArgumentError('invalid embedded P-256 public key');
      }
      final curve = ECCurve_secp256r1();
      final point = curve.curve.decodePoint(encoded)!;
      final x = point.x!;
      final y = point.y!;
      if (point.isInfinity ||
          y.square() != x.square() * x + curve.curve.a! * x + curve.curve.b!) {
        throw ArgumentError('embedded public key is not on P-256');
      }
      _publicKeys[entry.key] = ECPublicKey(point, curve);
    }
  }

  final String baselineId;
  final DateTime Function() clock;
  final Map<String, Object?> releaseIdentity;
  final Set<String> _revokedKeyIds;
  final _publicKeys = <String, ECPublicKey>{};

  /// Null means fail closed for this candidate; callers can boot bundled AOT.
  /// Expiry is an additional filter, not a trusted anti-replay counter.
  VerifiedManifest? verify(
    Uint8List envelopeBytes, {
    DateTime? now,
    bool allowExpiredHealthy = false,
    bool allowRevocation = false,
  }) {
    try {
      if (envelopeBytes.isEmpty || envelopeBytes.length > maxManifestBytes) {
        return null;
      }
      final source = utf8.decode(envelopeBytes, allowMalformed: false);
      _checkDepth(source);
      final envelope = jsonDecode(source);
      if (envelope is! Map<String, Object?> ||
          !_hasKeys(envelope, const {'manifest', 'signature'}) ||
          !_sameBytes(envelopeBytes, canonicalManifestBytes(envelope))) {
        return null;
      }
      // Exact canonical byte equality also rejects duplicate JSON keys before
      // any decoded value is trusted (jsonDecode alone keeps the last value).
      final manifest = envelope['manifest'];
      final signatureText = envelope['signature'];
      if (manifest is! Map<String, Object?> ||
          !_hasKeys(manifest, _manifestFields) ||
          manifest['schemaVersion'] != 1 ||
          manifest['signatureAlgorithm'] != signatureAlgorithm ||
          signatureText is! String ||
          signatureText.length > 96) {
        return null;
      }
      final keyId = manifest['keyId'];
      if (keyId is! String || _revokedKeyIds.contains(keyId)) return null;
      final key = _publicKeys[keyId];
      if (key == null) return null;
      final signatureBytes = base64.decode(signatureText);
      if (base64.encode(signatureBytes) != signatureText) return null;
      final verifier = ECDSASigner(SHA256Digest())
        ..init(false, PublicKeyParameter<ECPublicKey>(key));
      if (!verifier.verifySignature(
        canonicalManifestBytes(manifest),
        _decodeDerSignature(signatureBytes),
      )) {
        return null;
      }
      final identity = manifest['identity'];
      final patchId = manifest['patchId'];
      final hash = manifest['artifactSha256'];
      final size = manifest['artifactSize'];
      final rollout = manifest['rolloutPercent'];
      if (manifest['baselineId'] != baselineId ||
          identity is! Map<String, Object?> ||
          !_validIdentity(identity) ||
          releaseIdentity.entries.any((e) => identity[e.key] != e.value) ||
          patchId is! String ||
          !_identifierPattern.hasMatch(patchId) ||
          patchId == 'bundled' ||
          hash is! String ||
          !_sha256Pattern.hasMatch(hash) ||
          size is! int ||
          size <= 0 ||
          size > maxArtifactBytes ||
          rollout is! int ||
          rollout < 0 ||
          rollout > 100 ||
          manifest['revoked'] is! bool ||
          manifest['revoked'] == true && !allowRevocation) {
        return null;
      }
      final issuedAt = _timestamp(manifest['issuedAt']);
      final expiresAt = _timestamp(manifest['expiresAt']);
      final time = (now ?? clock()).toUtc();
      if (!expiresAt.isAfter(issuedAt) ||
          time.isBefore(issuedAt) ||
          !allowExpiredHealthy && !time.isBefore(expiresAt)) {
        return null;
      }
      return VerifiedManifest._(manifest);
    } on Object {
      return null;
    }
  }
}

bool _hasKeys(Map<String, Object?> map, Set<String> keys) =>
    map.length == keys.length && keys.every(map.containsKey);

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _validIdentity(Map<String, Object?> identity) =>
    _hasKeys(identity, releaseIdentityFields) &&
    identity.values.every(
      (value) => value is String && RegExp(r'^[!-~]{1,256}$').hasMatch(value),
    ) &&
    _sha256Pattern.hasMatch(identity['buildParametersSha256'] as String);

DateTime _timestamp(Object? value) {
  if (value is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(value)) {
    throw const FormatException('invalid manifest timestamp');
  }
  final result = DateTime.parse(value);
  if (result.toIso8601String() != value.replaceFirst('Z', '.000Z')) {
    throw const FormatException('non-canonical timestamp');
  }
  return result;
}

void _checkDepth(String source) {
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (final char in source.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (char == 92) {
        escaped = true;
      } else if (char == 34) {
        quoted = false;
      }
    } else if (char == 34) {
      quoted = true;
    } else if (char == 123 || char == 91) {
      if (++depth > 4) throw const FormatException('manifest too deep');
    } else if (char == 125 || char == 93) {
      if (--depth < 0) throw const FormatException('unbalanced manifest');
    }
  }
  if (quoted || depth != 0) throw const FormatException('incomplete manifest');
}

ECSignature _decodeDerSignature(Uint8List bytes) {
  // P-256's DER SEQUENCE has exactly two minimally encoded positive INTEGERs.
  // It is at most 72 bytes, so long-form/indefinite lengths are never needed.
  if (bytes.length < 8 ||
      bytes.length > 72 ||
      bytes[0] != 0x30 ||
      bytes[1] != bytes.length - 2) {
    throw const FormatException('invalid P-256 signature sequence');
  }
  var offset = 2;
  BigInt integer() {
    if (offset + 2 > bytes.length || bytes[offset++] != 2) {
      throw const FormatException('invalid signature integer');
    }
    final length = bytes[offset++];
    if (length == 0 ||
        length > 33 ||
        offset + length > bytes.length ||
        bytes[offset] >= 128 ||
        length > 1 && bytes[offset] == 0 && bytes[offset + 1] < 128) {
      throw const FormatException('non-canonical signature integer');
    }
    var value = BigInt.zero;
    for (var i = 0; i < length; i++) {
      value = (value << 8) | BigInt.from(bytes[offset++]);
    }
    return value;
  }

  final signature = ECSignature(integer(), integer());
  if (offset != bytes.length) {
    throw const FormatException('trailing signature data');
  }
  return signature;
}
