import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'signed_manifest.dart';
import 'signed_patch_loader.dart';

/// Called after startup health, never from Widget.build or patch activation.
/// Downloaded candidates enter the durable store but cannot change dispatch.
class UpdateClient {
  UpdateClient(
    this.loader,
    this.base, {
    this.allowDevelopmentHttp = false,
    this.artifactBase,
  }) {
    if (base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        !RegExp(r'^(?:/[A-Za-z0-9_-]+)*/?$').hasMatch(base.path) ||
        base.scheme != 'https' &&
            !(allowDevelopmentHttp && base.scheme == 'http')) {
      throw ArgumentError('HTTPS service origin required');
    }
    final cdn = artifactBase;
    if (cdn != null &&
        (cdn.host.isEmpty ||
            cdn.userInfo.isNotEmpty ||
            cdn.hasQuery ||
            cdn.hasFragment ||
            !cdn.path.endsWith('/') ||
            !RegExp(r'^(?:/[A-Za-z0-9_-]+)*/$').hasMatch(cdn.path) ||
            cdn.scheme != 'https' &&
                !(allowDevelopmentHttp && cdn.scheme == 'http'))) {
      throw ArgumentError('Trusted HTTPS artifact directory required');
    }
  }

  final SignedPatchLoader loader;
  final Uri base;
  final Uri? artifactBase;
  final bool allowDevelopmentHttp;
  final timeout = const Duration(seconds: 15);

  Uri _endpoint(String path) =>
      base.replace(path: base.path.replaceFirst(RegExp(r'/$'), '') + path);

  Future<Uint8List> _get(Uri uri, int limit) async {
    try {
      return await _getOnce(uri, limit);
    } on Object {
      // Retry whole bounded files; never append unverified partial bytes.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return _getOnce(uri, limit);
    }
  }

  Future<Uint8List> _getOnce(Uri uri, int limit) async {
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

  /// Persist before sending; retry on the next post-health check/startup.
  /// Event IDs deduplicate retries, not users. Telemetry never controls activation.
  Future<bool> report(String outcome, String? patchId) async {
    final id = loader.store.enqueueReport(
      loader.verifier.baselineId,
      patchId,
      outcome,
    );
    if (id == null) return false;
    return (await flushReports()).contains(id);
  }

  Future<Set<String>> flushReports() async {
    final delivered = <String>{};
    for (final event in loader.store.pendingReports()) {
      if (!await _sendReport(event)) break;
      if (!loader.store.acknowledgeReport(event['eventId'] as String)) break;
      delivered.add(event['eventId'] as String);
    }
    return delivered;
  }

  Future<bool> _sendReport(Map<String, dynamic> event) async {
    final client = http.Client();
    try {
      final request = http.Request('POST', _endpoint('/v1/reports'))
        ..followRedirects = false
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode(event);
      final response = await client.send(request).timeout(timeout);
      return response.statusCode == 202;
    } on Object catch (error) {
      print('HotfixDelivery report unavailable: $error');
      return false;
    } finally {
      client.close();
    }
  }

  Future<String> checkAndDownload({String? runningPatchId}) async {
    String? candidate;
    try {
      await flushReports();
      final withdrawals = jsonDecode(
        utf8.decode(
          await _get(
            _endpoint('/v1/withdrawals').replace(
              queryParameters: {'baselineId': loader.verifier.baselineId},
            ),
            128 * 1024,
          ),
        ),
      );
      if (withdrawals is! List || withdrawals.length > 64)
        throw const FormatException('withdrawal feed');
      for (final encoded in withdrawals) {
        if (encoded is! String ||
            !loader.withdrawSigned(base64.decode(encoded))) {
          await report('rejected', null);
          return 'rejected';
        }
      }
      final envelope = await _get(
        _endpoint(
          '/v1/check',
        ).replace(queryParameters: {'baselineId': loader.verifier.baselineId}),
        maxManifestBytes,
      );
      if (utf8.decode(envelope) == 'null') return 'no_update';
      final manifest = loader.verifier.verify(envelope, allowRevocation: true);
      if (manifest == null) {
        await report('rejected', null);
        return 'rejected';
      }
      if (manifest.revoked) {
        if (!loader.withdrawSigned(envelope)) return 'rejected';
        await report('withdrawn', manifest.patchId);
        return 'withdrawn';
      }
      if (!loader.eligible(manifest)) return 'not_selected';
      candidate = manifest.patchId;
      if (candidate == runningPatchId) return 'current';
      // Artifact location is derived from authenticated content, not a remote URL.
      final bytes = await _get(
        artifactBase?.resolve(manifest.artifactSha256) ??
            _endpoint('/v1/blobs/${manifest.artifactSha256}'),
        manifest.artifactSize,
      );
      if (!loader.stageBytes(envelope, bytes)) {
        await report('rejected', candidate);
        return 'rejected';
      }
      await report('downloaded', candidate);
      return 'downloaded';
    } on Object catch (error) {
      print('HotfixDelivery download unavailable: $error');
      await report('download_failed', candidate);
      return 'download_failed';
    }
  }
}
