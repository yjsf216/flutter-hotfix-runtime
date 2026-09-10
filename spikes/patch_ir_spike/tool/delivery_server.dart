import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import '../signed_manifest.dart';

const deliveryLimit = 8 * 1024 * 1024;
final _digest = RegExp(r'^[a-f0-9]{64}$');
final _id = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$');

Future<Uint8List> readBody(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream.timeout(const Duration(seconds: 15))) {
    if (bytes.length + chunk.length > limit)
      throw const FormatException('too large');
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

/// One local process + filesystem, no management UI or database required.
class DeliveryServer {
  DeliveryServer(this.root, this.publishToken, this.publicKeys) {
    if (publishToken.length < 24 || publicKeys.isEmpty) {
      throw ArgumentError('strong publish token and trust anchors required');
    }
    root.createSync(recursive: true);
  }
  final Directory root;
  final String publishToken;
  final Map<String, Uint8List> publicKeys;
  HttpServer? server;
  File _file(String name) => File('${root.path}/$name');

  void _atomic(String name, List<int> bytes) {
    final temp = _file('$name.tmp');
    temp.writeAsBytesSync(bytes, flush: true);
    temp.renameSync(_file(name).path);
  }

  Future<void> start({String host = '127.0.0.1', int port = 8080}) async {
    server = await HttpServer.bind(host, port);
    server!.listen((request) async {
      try {
        await _handle(request);
      } on Object catch (error) {
        try {
          request.response.statusCode = error is FormatException ? 400 : 500;
        } on Object {
          /* A disconnected streaming response already sent headers. */
        }
      } finally {
        try {
          await request.response.close();
        } on Object {
          /* A client disconnect must not terminate the publisher. */
        }
      }
    });
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    req.response.headers.contentType = ContentType.json;
    req.response.headers.set('cache-control', 'no-store');
    if (req.method == 'POST' && path == '/v1/releases') {
      if (req.headers.value('authorization') != 'Bearer $publishToken') {
        req.response.statusCode = 401;
        return;
      }
      final body = jsonDecode(
        utf8.decode(await readBody(req, deliveryLimit * 2)),
      );
      if (body is! Map ||
          body['envelope'] is! String ||
          body['artifact'] is! String) {
        throw const FormatException('upload envelope/artifact required');
      }
      final envelope = base64.decode(body['envelope'] as String);
      final bytes = base64.decode(body['artifact'] as String);
      if (envelope.length > maxManifestBytes || bytes.length > deliveryLimit) {
        req.response.statusCode = 413;
        return;
      }
      final decoded = jsonDecode(utf8.decode(envelope)) as Map;
      final manifest = decoded['manifest'] as Map;
      final baseline = manifest['baselineId'] as String;
      if (!_digest.hasMatch(baseline)) throw const FormatException('baseline');
      final verifier = SignedManifestVerifier(
        baselineId: baseline,
        releaseIdentity: Map<String, Object?>.from(manifest['identity'] as Map),
        publicKeys: publicKeys,
      );
      final verified = verifier.verify(envelope);
      if (verified == null ||
          verified.rolloutPercent != 100 ||
          !verified.matchesArtifact(bytes)) {
        req.response.statusCode = 422;
        return;
      }
      final record = '$baseline.${verified.patchId}.json';
      // No awaits during commit: immutable IDs and pointer updates serialize
      // in this isolate. ponytail: one server process per storage directory.
      if (_file(record).existsSync() &&
          sha256.convert(_file(record).readAsBytesSync()).toString() !=
              sha256.convert(envelope).toString()) {
        req.response.statusCode = 409;
        return;
      }
      _atomic('${verified.artifactSha256}.blob', bytes);
      _atomic(record, envelope);
      _atomic('$baseline.latest', envelope);
      req.response.statusCode = 201;
      req.response.write(
        jsonEncode({'baselineId': baseline, 'patchId': verified.patchId}),
      );
    } else if (req.method == 'GET' && path == '/v1/check') {
      final baseline = req.uri.queryParameters['baselineId'] ?? '';
      if (!_digest.hasMatch(baseline)) throw const FormatException('baseline');
      final file = _file('$baseline.latest');
      req.response.add(
        file.existsSync() ? file.readAsBytesSync() : utf8.encode('null'),
      );
    } else if (req.method == 'GET' && path.startsWith('/v1/blobs/')) {
      final digest = path.substring('/v1/blobs/'.length);
      if (!_digest.hasMatch(digest)) throw const FormatException('digest');
      final file = _file('$digest.blob');
      if (!file.existsSync()) {
        req.response.statusCode = 404;
        return;
      }
      req.response.headers.contentType = ContentType.binary;
      await req.response.addStream(file.openRead());
    } else if (req.method == 'POST' && path == '/v1/reports') {
      final report = jsonDecode(utf8.decode(await readBody(req, 4096)));
      const outcomes = {
        'baseline_healthy',
        'patch_healthy',
        'startup_failed',
        'downloaded',
        'rejected',
        'download_failed',
      };
      if (report is! Map ||
          report.length != 3 ||
          report['baselineId'] is! String ||
          !_digest.hasMatch(report['baselineId']) ||
          !outcomes.contains(report['outcome']) ||
          report['patchId'] != null &&
              (report['patchId'] is! String ||
                  !_id.hasMatch(report['patchId']))) {
        throw const FormatException('report');
      }
      final file = _file('reports.jsonl');
      // Untrusted observations, never used as an activation or rollback command.
      if (file.existsSync() && file.lengthSync() > 10 * 1024 * 1024) {
        req.response.statusCode = 507;
        return;
      }
      file.writeAsStringSync(
        '${jsonEncode({...report, 'receivedAt': DateTime.now().toUtc().toIso8601String()})}\n',
        mode: FileMode.append,
        flush: true,
      );
      req.response.statusCode = 202;
    } else {
      req.response.statusCode = 404;
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 2)
    throw ArgumentError('delivery_server.dart STORAGE PUBLIC_KEY_FILE');
  final service = DeliveryServer(
    Directory(args[0]),
    Platform.environment['HOTFIX_PUBLISH_TOKEN'] ?? '',
    {'spike-p256-1': base64.decode(File(args[1]).readAsStringSync().trim())},
  );
  await service.start(
    host: Platform.environment['HOTFIX_BIND'] ?? '127.0.0.1',
    port: int.parse(Platform.environment['HOTFIX_PORT'] ?? '8080'),
  );
  print(
    'Delivery service listening on ${service.server!.address.address}:${service.server!.port}',
  );
}
