import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'signed_manifest.dart';
import 'signed_patch_loader.dart';

/// Called after startup health, never from Widget.build or patch activation.
/// Downloaded candidates enter the durable store but cannot change dispatch.
class UpdateClient {
  UpdateClient(this.loader, this.base, {this.allowDevelopmentHttp = false}) {
    if (base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        base.path != '' && base.path != '/' ||
        base.scheme != 'https' &&
            !(allowDevelopmentHttp && base.scheme == 'http')) {
      throw ArgumentError('HTTPS service origin required');
    }
  }

  final SignedPatchLoader loader;
  final Uri base;
  final bool allowDevelopmentHttp;
  final timeout = const Duration(seconds: 15);

  Future<Uint8List> _get(Uri uri, int limit) async {
    final client = http.Client();
    try {
      return await (() async {
        final request = http.Request('GET', uri)..followRedirects = false;
        final response = await client.send(request);
        if (response.statusCode != 200 ||
            response.contentLength != null && response.contentLength! > limit) {
          throw StateError('download rejected: HTTP ${response.statusCode}');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > limit) {
            throw const FormatException('download too large');
          }
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      })().timeout(timeout);
    } finally {
      client.close();
    }
  }

  /// ponytail: telemetry is best effort; add a durable outbox before production.
  /// It carries no device/user identifiers and never
  /// determines activation. A collector must treat client reports as untrusted.
  Future<bool> report(String outcome, String? patchId) async {
    final client = http.Client();
    try {
      final request = http.Request('POST', base.resolve('/v1/reports'))
        ..followRedirects = false
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode({
          'baselineId': loader.verifier.baselineId,
          'patchId': patchId,
          'outcome': outcome,
        });
      final response = await client.send(request).timeout(timeout);
      return response.statusCode == 202;
    } on Object {
      return false;
    } finally {
      client.close();
    }
  }

  Future<String> checkAndDownload({String? runningPatchId}) async {
    String? candidate;
    try {
      final envelope = await _get(
        base
            .resolve('/v1/check')
            .replace(
              queryParameters: {'baselineId': loader.verifier.baselineId},
            ),
        maxManifestBytes,
      );
      if (utf8.decode(envelope) == 'null') return 'no_update';
      final manifest = loader.verifier.verify(envelope);
      if (manifest == null || manifest.rolloutPercent != 100) {
        await report('rejected', null);
        return 'rejected';
      }
      candidate = manifest.patchId;
      if (candidate == runningPatchId) return 'current';
      // Artifact location is derived from authenticated content, not a remote URL.
      final bytes = await _get(
        base.resolve('/v1/blobs/${manifest.artifactSha256}'),
        manifest.artifactSize,
      );
      if (!loader.stageBytes(envelope, bytes)) {
        await report('rejected', candidate);
        return 'rejected';
      }
      await report('downloaded', candidate);
      return 'downloaded';
    } on Object {
      await report('download_failed', candidate);
      return 'download_failed';
    }
  }
}
