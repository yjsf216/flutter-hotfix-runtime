import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import '../signed_manifest.dart';

/// Server-side ossutil upload followed by a bounded CDN content check.
class OssArtifactStore {
  OssArtifactStore(
    this.executable,
    this.configFile,
    this.bucket,
    this.prefix,
    this.cdnBase,
  ) {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$').hasMatch(bucket) ||
        !RegExp(r'^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*$').hasMatch(prefix) ||
        cdnBase.scheme != 'https' ||
        cdnBase.host.isEmpty ||
        cdnBase.userInfo.isNotEmpty ||
        cdnBase.hasQuery ||
        cdnBase.hasFragment ||
        !cdnBase.path.endsWith('/')) {
      throw ArgumentError(
        'Explicit OSS bucket/prefix and HTTPS CDN directory required',
      );
    }
  }

  final String executable;
  final String configFile;
  final String bucket;
  final String prefix;
  final Uri cdnBase;

  Future<void> store(VerifiedManifest manifest, Uint8List bytes) async {
    if (!manifest.matchesArtifact(bytes)) throw StateError('Artifact mismatch');
    final temporary = await Directory.systemTemp.createTemp('hotfix-oss.');
    try {
      final source = File('${temporary.path}/patch.bytecode');
      await source.writeAsBytes(bytes, flush: true);
      await storeFile(source, manifest.artifactSha256, manifest.artifactSize);
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  /// Stream installation packages without keeping them in service memory.
  Future<Uri> storeFile(File source, String hash, int size) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        size <= 0 ||
        size > 1024 * 1024 * 1024 ||
        await source.length() != size ||
        (await sha256.bind(source.openRead()).first).toString() != hash) {
      throw StateError('Source artifact mismatch');
    }
    // Existing digest URLs are immutable. Verify rather than overwrite them.
    await source.setLastModified(DateTime.fromMillisecondsSinceEpoch(0));
    final environment = Map<String, String>.from(Platform.environment)
      ..removeWhere((key, _) => key.startsWith('HOTFIX_'));
    final downloadName = source.path.endsWith('.apk') ? 'app.apk' :
        source.path.endsWith('.ipa') ? 'app.ipa' : null;
    final process = await Process.start(
      executable,
      [
        'cp',
        source.path,
        'oss://$bucket/$prefix/v1/blobs/$hash',
        '-u',
        '-c',
        configFile,
        '--retry-times',
        '1',
        '--meta',
        'Content-Type:application/octet-stream#Cache-Control:public,max-age=31536000,immutable'
            '${downloadName == null ? '' : '#Content-Disposition:attachment; filename="$downloadName"'}',
      ],
      environment: environment,
      includeParentEnvironment: false,
    );
    final drained = Future.wait([
      process.stdout.drain<void>(),
      process.stderr.drain<void>(),
    ]);
    int exit;
    try {
      exit = await process.exitCode.timeout(const Duration(seconds: 90));
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      rethrow;
    } finally {
      await drained;
    }
    if (exit != 0) throw StateError('Object storage upload failed');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      await (() async {
        final request = await client.getUrl(cdnBase.resolve(hash));
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close();
        if (response.statusCode != 200 || response.contentLength > size) {
          throw StateError('CDN artifact unavailable');
        }
        var received = 0;
        final checked = response.map((chunk) {
          received += chunk.length;
          if (received > size) {
            throw StateError('CDN artifact too large');
          }
          return chunk;
        });
        final actual = await sha256.bind(checked).first;
        if (received != size || actual.toString() != hash) {
          throw StateError('CDN artifact mismatch');
        }
      })().timeout(const Duration(seconds: 90));
    } finally {
      client.close(force: true);
    }
    return cdnBase.resolve(hash);
  }
}
