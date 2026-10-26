import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import '../signed_manifest.dart';
import 'oss_artifact_store.dart';

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
  DeliveryServer(
    this.root,
    this.publishToken,
    this.publicKeys, {
    this.uploadToken,
    this.storeArtifact,
    this.extraRoute,
    this.isRetired,
    this.isBlobRetired,
    this.mutationGate,
  }) {
    if (publishToken.length < 24 || publicKeys.isEmpty) {
      throw ArgumentError('strong publish token and trust anchors required');
    }
    if (uploadToken != null &&
        (uploadToken!.length < 24 || uploadToken == publishToken)) {
      throw ArgumentError('separate strong upload token required');
    }
    root.createSync(recursive: true);
    final reports = _file('reports.jsonl');
    if (reports.existsSync()) {
      if (reports.lengthSync() > 11 * 1024 * 1024)
        throw StateError('report log exceeds limit');
      var bytes = reports.readAsBytesSync();
      if (bytes.isNotEmpty && bytes.last != 10) {
        // A crash during append leaves an unacknowledged tail; the client retries.
        bytes = bytes.sublist(0, bytes.lastIndexOf(10) + 1);
        _atomic('reports.jsonl', bytes);
        stderr.writeln('Recovered incomplete final report record');
      }
      for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
        final record = jsonDecode(line) as Map<String, dynamic>;
        final eventId = record['eventId'];
        if (eventId is String) {
          _reports[eventId] = Map.of(record)..remove('receivedAt');
        }
      }
    }
  }
  final Directory root;
  final String publishToken;
  final String? uploadToken;
  final Future<bool> Function(HttpRequest)? extraRoute;
  final bool Function(String)? isRetired, isBlobRetired;
  final Future<void> Function(Future<void> Function())? mutationGate;
  final Future<void> Function(VerifiedManifest manifest, Uint8List bytes)?
  storeArtifact;
  final Map<String, Uint8List> publicKeys;
  HttpServer? server;
  final _reports = <String, Map<String, dynamic>>{};
  File _file(String name) => File('${root.path}/$name');

  bool _isPublished(String key) {
    final file = _file('$key.json');
    return file.existsSync() &&
        (jsonDecode(file.readAsStringSync()) as Map)['manifest']['revoked'] !=
            true;
  }

  Map<String, int> _numbers(String baseline) {
    final file = _file('$baseline.numbers');
    if (!file.existsSync()) return {};
    if (file.lengthSync() > 2 * 1024 * 1024)
      throw StateError('Number ledger too large');
    return Map<String, int>.from(jsonDecode(file.readAsStringSync()) as Map);
  }

  int _reserveNumber(String baseline, String patchId) {
    final numbers = _numbers(baseline);
    if (numbers.containsKey(patchId)) return numbers[patchId]!;
    if (numbers.length >= 10000) throw StateError('Number ledger full');
    final number = numbers.values.fold(0, (a, b) => a > b ? a : b) + 1;
    if (number > 1000000) throw StateError('Number limit');
    numbers[patchId] = number;
    _atomic('$baseline.numbers', utf8.encode(jsonEncode(numbers)));
    return number;
  }

  bool _claimNumber(VerifiedManifest manifest) {
    final number = manifest.patchNumber;
    if (number == null) return true;
    final numbers = _numbers(manifest.baselineId);
    if (numbers.containsKey(manifest.patchId))
      return numbers[manifest.patchId] == number;
    if (numbers.length >= 10000 || numbers.values.any((n) => n >= number))
      return false;
    numbers[manifest.patchId] = number;
    _atomic('${manifest.baselineId}.numbers', utf8.encode(jsonEncode(numbers)));
    return true;
  }

  void _atomic(String name, List<int> bytes) {
    final temp = _file('$name.tmp');
    temp.writeAsBytesSync(bytes, flush: true);
    temp.renameSync(_file(name).path);
  }

  Future<void> start({String host = '127.0.0.1', int port = 8080}) async {
    server = await HttpServer.bind(host, port);
    server!.listen((request) async {
      try {
        if (request.method == 'POST' && mutationGate != null) {
          await mutationGate!(() => _handle(request));
        } else {
          await _handle(request);
        }
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
    if (extraRoute != null && await extraRoute!(req)) return;
    final uploadAction = RegExp(
      r'^/v1/uploads/([a-f0-9]{64})/([a-zA-Z0-9][a-zA-Z0-9._-]{0,127})/(delete|restore)$',
    ).firstMatch(path);
    if (req.method == 'POST' && uploadAction != null) {
      if (req.headers.value('authorization') != 'Bearer $publishToken') {
        req.response.statusCode = 401;
        return;
      }
      final bytes = await readBody(req, 4096);
      if (bytes.isNotEmpty) {
        final body = jsonDecode(utf8.decode(bytes));
        if (body is! Map || body.isNotEmpty) {
          throw const FormatException('empty action body required');
        }
      }
      final key = '${uploadAction[1]}.${uploadAction[2]}';
      if (isRetired?.call(uploadAction[1]!) == true) {
        req.response.statusCode = 410;
        return;
      }
      if (!_file('$key.candidate').existsSync()) {
        req.response.statusCode = 404;
        return;
      }
      final removing = uploadAction[3] == 'delete';
      if (removing && _isPublished(key)) {
        req.response.statusCode = 409;
        return;
      }
      // Listing-only tombstones: retain signed content, revocations and numbers.
      final marker = _file('$key.deleted');
      if (removing && !marker.existsSync()) {
        _atomic(
          '$key.deleted',
          utf8.encode(DateTime.now().toUtc().toIso8601String()),
        );
      } else if (!removing && marker.existsSync()) {
        marker.deleteSync();
      }
      req.response.write(
        jsonEncode({'status': removing ? 'deleted' : 'restored'}),
      );
      return;
    }
    if (req.method == 'POST' && path == '/v1/patch-numbers') {
      if (req.headers.value('authorization') !=
          'Bearer ${uploadToken ?? publishToken}') {
        req.response.statusCode = 401;
        return;
      }
      final body = jsonDecode(utf8.decode(await readBody(req, 4096)));
      if (body is! Map ||
          body.length != 2 ||
          body['baselineId'] is! String ||
          !_digest.hasMatch(body['baselineId']) ||
          body['patchId'] is! String ||
          !_id.hasMatch(body['patchId']) ||
          body['patchId'] == 'bundled') {
        throw const FormatException('number reservation');
      }
      // No awaits between read/increment/atomic rename: one service process
      // owns the ledger. Reservations survive failed builds and withdrawals.
      if (isRetired?.call(body['baselineId'] as String) == true) {
        req.response.statusCode = 410;
        return;
      }
      final number = _reserveNumber(body['baselineId'], body['patchId']);
      req.response.write(jsonEncode({...body, 'patchNumber': number}));
      return;
    }
    if (req.method == 'GET' && path == '/v1/uploads') {
      if (req.headers.value('authorization') != 'Bearer $publishToken') {
        req.response.statusCode = 401;
        return;
      }
      final records = <Map<String, dynamic>>[];
      var count = 0;
      await for (final entry in root.list(followLinks: false)) {
        if (entry is! File || !entry.path.endsWith('.candidate')) continue;
        final manifest =
            (jsonDecode(entry.readAsStringSync()) as Map)['manifest'] as Map;
        final baseline = manifest['baselineId'] as String;
        if (isRetired?.call(baseline) == true) continue;
        if (++count > 500) {
          req.response.statusCode = 507;
          return;
        }
        final patch = manifest['patchId'] as String;
        final deleted = _file('$baseline.$patch.deleted');
        if (deleted.existsSync() &&
            req.uri.queryParameters['includeDeleted'] != '1') {
          continue;
        }
        final uploaded = _file('$baseline.$patch.uploaded');
        final released = _file('$baseline.$patch.json');
        final published = released.existsSync()
            ? (jsonDecode(released.readAsStringSync()) as Map)['manifest']
                  as Map
            : null;
        records.add({
          'manifest': manifest,
          // Legacy records predate the timestamp sidecar; retain their file time.
          'uploadedAt': uploaded.existsSync()
              ? uploaded.readAsStringSync()
              : entry.lastModifiedSync().toUtc().toIso8601String(),
          if (deleted.existsSync()) 'deletedAt': deleted.readAsStringSync(),
          'status': published == null
              ? 'uploaded'
              : published['revoked'] == true
              ? 'withdrawn'
              : 'published',
          'withdrawalUploaded': _file(
            '$baseline.$patch.withdrawal',
          ).existsSync(),
        });
      }
      records.sort((a, b) {
        final order = DateTime.parse(
          b['uploadedAt'] as String,
        ).compareTo(DateTime.parse(a['uploadedAt'] as String));
        return order != 0
            ? order
            : '${a['manifest']['baselineId']}/${a['manifest']['patchId']}'
                  .compareTo(
                    '${b['manifest']['baselineId']}/${b['manifest']['patchId']}',
                  );
      });
      req.response.write(jsonEncode(records));
      return;
    }
    if (req.method == 'POST' && path == '/v1/pause') {
      if (req.headers.value('authorization') != 'Bearer $publishToken') {
        req.response.statusCode = 401;
        return;
      }
      final body = jsonDecode(utf8.decode(await readBody(req, 4096)));
      if (body is! Map ||
          body.length != 2 ||
          body['baselineId'] is! String ||
          !_digest.hasMatch(body['baselineId']) ||
          body['paused'] is! bool) {
        throw const FormatException('pause requires baselineId and paused');
      }
      _atomic('${body['baselineId']}.paused', utf8.encode('${body['paused']}'));
      req.response.statusCode = 204;
      return;
    }
    if (req.method == 'GET' && path == '/v1/withdrawals') {
      final baseline = req.uri.queryParameters['baselineId'] ?? '';
      if (!_digest.hasMatch(baseline)) throw const FormatException('baseline');
      final file = _file('$baseline.withdrawals');
      req.response.add(
        file.existsSync() ? file.readAsBytesSync() : utf8.encode('[]'),
      );
      return;
    }
    if (req.method == 'GET' && path == '/v1/stats') {
      if (req.headers.value('authorization') != 'Bearer $publishToken') {
        req.response.statusCode = 401;
        return;
      }
      final counts = <String, int>{};
      for (final event in _reports.values) {
        final key =
            '${event['baselineId']}/${event['patchId'] ?? 'bundled'}/${event['outcome']}';
        counts[key] = (counts[key] ?? 0) + 1;
      }
      req.response.write(
        jsonEncode({'eventCounts': counts, 'uniqueUsers': null}),
      );
      return;
    }
    if (req.method == 'POST' &&
        (path == '/v1/releases' ||
            path == '/v1/uploads' ||
            path == '/v1/activate')) {
      final staging = path == '/v1/uploads';
      final requiredToken = staging ? uploadToken : publishToken;
      if (requiredToken == null ||
          req.headers.value('authorization') != 'Bearer $requiredToken') {
        req.response.statusCode = 401;
        return;
      }
      var body = jsonDecode(
        utf8.decode(await readBody(req, deliveryLimit * 2)),
      );
      if (path == '/v1/activate') {
        if (body is! Map ||
            body.length != 3 ||
            body['baselineId'] is! String ||
            !_digest.hasMatch(body['baselineId']) ||
            body['patchId'] is! String ||
            !_id.hasMatch(body['patchId']) ||
            !{'candidate', 'withdrawal'}.contains(body['kind'])) {
          throw const FormatException('activation identity');
        }
        final selected = _file(
          '${body['baselineId']}.${body['patchId']}.${body['kind']}',
        );
        if (!selected.existsSync()) {
          req.response.statusCode = 404;
          return;
        }
        if (body['kind'] == 'candidate' &&
            _file(
              '${body['baselineId']}.${body['patchId']}.deleted',
            ).existsSync()) {
          req.response.statusCode = 409;
          return;
        }
        final envelope = selected.readAsBytesSync();
        final manifest =
            (jsonDecode(utf8.decode(envelope)) as Map)['manifest'] as Map;
        final digest = manifest['artifactSha256'];
        if (digest is! String || !_digest.hasMatch(digest)) {
          throw const FormatException('staged artifact digest');
        }
        body = {
          'envelope': base64.encode(envelope),
          'artifact': base64.encode(_file('$digest.blob').readAsBytesSync()),
        };
      }
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
      final verified = verifier.verify(envelope, allowRevocation: true);
      if (verified == null || !verified.matchesArtifact(bytes)) {
        req.response.statusCode = 422;
        return;
      }
      if (isRetired?.call(baseline) == true) {
        req.response.statusCode = 410;
        return;
      }
      if (!_claimNumber(verified)) {
        req.response.statusCode = 409;
        return;
      }
      if (staging) {
        final staged =
            '$baseline.${verified.patchId}.${verified.revoked ? 'withdrawal' : 'candidate'}';
        final existing = _file(staged);
        if (existing.existsSync() &&
            sha256.convert(existing.readAsBytesSync()) !=
                sha256.convert(envelope)) {
          req.response.statusCode = 409;
          return;
        }
        // A failed external upload/verification must never create a ready candidate.
        if (!verified.revoked) await storeArtifact?.call(verified, bytes);
        if (isRetired?.call(baseline) == true) {
          req.response.statusCode = 410;
          return;
        }
        if (existing.existsSync() &&
            sha256.convert(existing.readAsBytesSync()) !=
                sha256.convert(envelope)) {
          req.response.statusCode = 409;
          return;
        }
        // Upload credentials can stage signed content but never change release pointers.
        _atomic('${verified.artifactSha256}.blob', bytes);
        if (!existing.existsSync()) _atomic(staged, envelope);
        if (!verified.revoked &&
            !_file('$baseline.${verified.patchId}.uploaded').existsSync()) {
          _atomic(
            '$baseline.${verified.patchId}.uploaded',
            utf8.encode(existing.lastModifiedSync().toUtc().toIso8601String()),
          );
        }
        req.response.statusCode = 201;
        req.response.write(
          jsonEncode({
            'baselineId': baseline,
            'patchId': verified.patchId,
            if (verified.patchNumber != null)
              'patchNumber': verified.patchNumber,
            'artifactSha256': verified.artifactSha256,
            'status': 'uploaded',
          }),
        );
        return;
      }
      if (!verified.revoked) await storeArtifact?.call(verified, bytes);
      if (isRetired?.call(baseline) == true) {
        req.response.statusCode = 410;
        return;
      }
      final record = '$baseline.${verified.patchId}.json';
      // Recheck after external storage awaits, including the legacy release API.
      if (!verified.revoked &&
          _file('$baseline.${verified.patchId}.deleted').existsSync()) {
        req.response.statusCode = 409;
        return;
      }
      // No awaits during commit: immutable IDs and pointer updates serialize
      // in this isolate. ponytail: one server process per storage directory.
      if (_file(record).existsSync() &&
          sha256.convert(_file(record).readAsBytesSync()).toString() !=
              sha256.convert(envelope).toString()) {
        final previous =
            (jsonDecode(_file(record).readAsStringSync()) as Map)['manifest']
                as Map;
        Map<String, dynamic> payload(Map source) =>
            Map<String, dynamic>.from(source)
              ..remove('rolloutPercent')
              ..remove('revoked')
              ..remove('issuedAt')
              ..remove('expiresAt');
        if (utf8.decode(canonicalManifestBytes(payload(previous))) !=
                utf8.decode(canonicalManifestBytes(payload(manifest))) ||
            previous['revoked'] == true && manifest['revoked'] != true ||
            !DateTime.parse(
              manifest['issuedAt'] as String,
            ).isAfter(DateTime.parse(previous['issuedAt'] as String))) {
          req.response.statusCode = 409;
          return;
        }
      }
      if (verified.revoked) {
        final file = _file('$baseline.withdrawals');
        final controls = file.existsSync()
            ? (jsonDecode(file.readAsStringSync()) as List).cast<String>()
            : <String>[];
        controls.removeWhere(
          (encoded) =>
              (jsonDecode(utf8.decode(base64.decode(encoded)))
                  as Map)['manifest']['patchId'] ==
              verified.patchId,
        );
        controls.add(base64.encode(envelope));
        final encoded = utf8.encode(jsonEncode(controls));
        if (controls.length > 64 || encoded.length > 128 * 1024) {
          req.response.statusCode = 507;
          return;
        }
        _atomic('$baseline.withdrawals', encoded);
      }
      _atomic('${verified.artifactSha256}.blob', bytes);
      _atomic(record, envelope);
      final latest = _file('$baseline.latest');
      // A historical withdrawal must not stop a different current patch.
      if (!verified.revoked ||
          !latest.existsSync() ||
          (jsonDecode(latest.readAsStringSync())
                  as Map)['manifest']['patchId'] ==
              verified.patchId) {
        _atomic('$baseline.latest', envelope);
      }
      req.response.statusCode = 201;
      req.response.write(
        jsonEncode({'baselineId': baseline, 'patchId': verified.patchId}),
      );
    } else if (req.method == 'GET' && path == '/v1/check') {
      final baseline = req.uri.queryParameters['baselineId'] ?? '';
      if (!_digest.hasMatch(baseline)) throw const FormatException('baseline');
      final file = _file('$baseline.latest');
      final paused = _file('$baseline.paused');
      req.response.add(
        isRetired?.call(baseline) != true &&
                file.existsSync() &&
                !(paused.existsSync() && paused.readAsStringSync() == 'true')
            ? file.readAsBytesSync()
            : utf8.encode('null'),
      );
    } else if (req.method == 'GET' && path.startsWith('/v1/blobs/')) {
      final digest = path.substring('/v1/blobs/'.length);
      if (!_digest.hasMatch(digest)) throw const FormatException('digest');
      if (isBlobRetired?.call(digest) == true) {
        req.response.statusCode = 410;
        return;
      }
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
        'withdrawn',
      };
      if (report is! Map ||
          (report.length != 3 && report.length != 4) ||
          !report.keys.toSet().containsAll({
            'baselineId',
            'patchId',
            'outcome',
          }) ||
          report.length == 4 &&
              (report['eventId'] is! String ||
                  !RegExp(r'^[a-f0-9]{32}$').hasMatch(report['eventId'])) ||
          report['baselineId'] is! String ||
          !_digest.hasMatch(report['baselineId']) ||
          !outcomes.contains(report['outcome']) ||
          report['patchId'] != null &&
              (report['patchId'] is! String ||
                  !_id.hasMatch(report['patchId']))) {
        throw const FormatException('report');
      }
      final file = _file('reports.jsonl');
      final eventId = report['eventId'];
      if (eventId is String && _reports.containsKey(eventId)) {
        req.response.statusCode =
            utf8.decode(canonicalManifestBytes(_reports[eventId])) ==
                utf8.decode(
                  canonicalManifestBytes(Map<String, dynamic>.from(report)),
                )
            ? 202
            : 409;
        return;
      }
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
      if (eventId is String)
        _reports[eventId] = Map<String, dynamic>.from(report);
      req.response.statusCode = 202;
    } else {
      req.response.statusCode = 404;
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 2)
    throw ArgumentError('delivery_server.dart STORAGE PUBLIC_KEY_FILE');
  final env = Platform.environment;
  final objectStore = env['HOTFIX_OSS_BUCKET'] == null
      ? null
      : OssArtifactStore(
          env['HOTFIX_OSSUTIL']!,
          env['HOTFIX_OSS_CONFIG']!,
          env['HOTFIX_OSS_BUCKET']!,
          env['HOTFIX_OSS_PREFIX']!,
          Uri.parse(env['HOTFIX_CDN_BLOB_BASE']!),
        );
  final service = DeliveryServer(
    Directory(args[0]),
    Platform.environment['HOTFIX_PUBLISH_TOKEN'] ?? '',
    {'spike-p256-1': base64.decode(File(args[1]).readAsStringSync().trim())},
    uploadToken: Platform.environment['HOTFIX_UPLOAD_TOKEN'],
    storeArtifact: objectStore?.store,
  );
  await service.start(
    host: Platform.environment['HOTFIX_BIND'] ?? '127.0.0.1',
    port: int.parse(Platform.environment['HOTFIX_PORT'] ?? '8080'),
  );
  print(
    'Delivery service listening on ${service.server!.address.address}:${service.server!.port}',
  );
}
