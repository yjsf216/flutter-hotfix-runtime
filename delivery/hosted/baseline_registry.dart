import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import '../../spikes/patch_ir_spike/tool/delivery_server.dart' show readBody;
import '../../spikes/patch_ir_spike/lib/signed_manifest.dart'
    show canonicalManifestBytes;

/// Authenticated, resumable package staging; a baseline becomes visible only
/// after both its complete local hash and server-owned CDN copy are verified.
class BaselineRegistry {
  BaselineRegistry(
    this.root,
    this.adminToken,
    this.uploadToken,
    this.storeFile, {
    this.isRetired,
  }) {
    root.createSync(recursive: true);
  }
  final Directory root;
  final String adminToken, uploadToken;
  final Future<Uri> Function(File, String, int) storeFile;
  final bool Function(String)? isRetired;
  final busy = <String>{};
  static const chunkSize = 4 * 1024 * 1024;
  static final digest = RegExp(r'^[a-f0-9]{64}$');
  static final commit = RegExp(r'^[a-f0-9]{40}$');

  Map<String, dynamic> validate(dynamic value) {
    const keys = {
      'baselineId',
      'appId',
      'platform',
      'release',
      'gitCommit',
      'sourceCommit',
      'sourceBranch',
      'packageSha256',
      'packageSize',
    };
    if (value is! Map ||
        value.length != keys.length ||
        !value.keys.toSet().containsAll(keys)) {
      throw const FormatException('baseline metadata');
    }
    final m = Map<String, dynamic>.from(value);
    bool matches(String key, RegExp pattern) =>
        m[key] is String && pattern.hasMatch(m[key]);
    if (!matches('baselineId', digest) ||
        !matches('packageSha256', digest) ||
        !matches('gitCommit', commit) ||
        !matches('sourceCommit', commit) ||
        !matches('appId', RegExp(r'^[a-zA-Z0-9_.-]{1,200}$')) ||
        !matches('release', RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$')) ||
        !matches('sourceBranch', RegExp(r'^[a-zA-Z0-9_./-]{1,200}$')) ||
        !['android', 'ios'].contains(m['platform']) ||
        m['packageSize'] is! int ||
        m['packageSize'] <= 0 ||
        m['packageSize'] > 1024 * 1024 * 1024) {
      throw const FormatException('baseline fields');
    }
    return m;
  }

  Future<bool> handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path != '/v1/baselines' && !path.startsWith('/v1/baselines/'))
      return false;
    final management = RegExp(
      r'^/v1/baselines/([a-f0-9]{64})/(delete|restore)$',
    ).firstMatch(path);
    final auth = request.headers.value('authorization');
    if (auth !=
        'Bearer ${request.method == 'GET' || management != null ? adminToken : uploadToken}') {
      request.response.statusCode = 401;
      return true;
    }
    if (request.method == 'GET' && path == '/v1/baselines') {
      final records = <Map<String, dynamic>>[];
      for (final f in root.listSync(followLinks: false).whereType<File>()) {
        if (!RegExp(r'^[a-f0-9]{64}\.json$').hasMatch(f.uri.pathSegments.last))
          continue;
        final record = Map<String, dynamic>.from(
          jsonDecode(f.readAsStringSync()),
        );
        if (isRetired?.call(record['baselineId'] as String) == true) continue;
        final deleted = File('${root.path}/${record['baselineId']}.deleted');
        if (deleted.existsSync()) {
          if (request.uri.queryParameters['includeDeleted'] != '1') continue;
          record['deletedAt'] = deleted.readAsStringSync();
        }
        records.add(record);
      }
      records.sort(
        (a, b) => DateTime.parse(
          b['registeredAt'],
        ).compareTo(DateTime.parse(a['registeredAt'])),
      );
      request.response.write(jsonEncode(records));
      return true;
    }
    if (request.method != 'POST') {
      request.response.statusCode = 404;
      return true;
    }
    if (management != null) {
      final bytes = await readBody(request, 1024);
      if (bytes.isNotEmpty) {
        final body = jsonDecode(utf8.decode(bytes));
        if (body is! Map || body.isNotEmpty)
          throw const FormatException('Empty action body required');
      }
      final id = management[1]!;
      if (isRetired?.call(id) == true) {
        request.response.statusCode = 410;
        return true;
      }
      if (!busy.add(id)) {
        request.response.statusCode = 409;
        return true;
      }
      try {
        final record = File('${root.path}/$id.json');
        if (!record.existsSync()) {
          request.response.statusCode = 404;
          return true;
        }
        final deleted = File('${root.path}/$id.deleted');
        if (management[2] == 'delete') {
          // A recoverable listing action only. Package blobs, signed policies,
          // installed apps and immutable baseline metadata remain untouched.
          if (!deleted.existsSync()) {
            final temp = File('${deleted.path}.tmp')
              ..writeAsStringSync(
                DateTime.now().toUtc().toIso8601String(),
                flush: true,
              );
            temp.renameSync(deleted.path);
          }
        } else if (deleted.existsSync()) {
          deleted.deleteSync();
        }
        request.response.write(
          jsonEncode({
            'baselineId': id,
            'status': management[2] == 'delete' ? 'deleted' : 'restored',
          }),
        );
        return true;
      } finally {
        busy.remove(id);
      }
    }
    Map<String, dynamic>? metadata;
    String id;
    final match = RegExp(
      r'^/v1/baselines/([a-f0-9]{64})/(finish|chunks/([0-9]{1,4}))$',
    ).firstMatch(path);
    if (path == '/v1/baselines') {
      metadata = validate(
        jsonDecode(utf8.decode(await readBody(request, 8192))),
      );
      id = metadata['baselineId'];
    } else if (match != null) {
      id = match[1]!;
    } else {
      request.response.statusCode = 404;
      return true;
    }
    if (isRetired?.call(id) == true) {
      request.response.statusCode = 410;
      return true;
    }
    if (!busy.add(id)) {
      request.response.statusCode = 409;
      return true;
    }
    final pending = Directory('${root.path}/$id.pending');
    final complete = File('${root.path}/$id.json');
    final metaFile = File('${pending.path}/metadata.json');
    try {
      if (metadata != null) {
        if (complete.existsSync()) {
          final existing = jsonDecode(complete.readAsStringSync()) as Map;
          existing.remove('packageUrl');
          existing.remove('registeredAt');
          if (utf8.decode(canonicalManifestBytes(existing)) !=
              utf8.decode(canonicalManifestBytes(metadata))) {
            request.response.statusCode = 409;
            return true;
          }
          request.response.write(
            jsonEncode({'status': 'registered', 'baselineId': id}),
          );
          return true;
        }
        final encoded = utf8.decode(canonicalManifestBytes(metadata));
        if (metaFile.existsSync() && metaFile.readAsStringSync() != encoded) {
          request.response.statusCode = 409;
          return true;
        }
        if (!pending.existsSync() &&
            root.listSync().whereType<Directory>().length >= 20) {
          request.response.statusCode = 507;
          return true;
        }
        pending.createSync();
        metaFile.writeAsStringSync(encoded, flush: true);
        request.response.write(
          jsonEncode({
            'status': 'staging',
            'baselineId': id,
            'chunkSize': chunkSize,
          }),
        );
        return true;
      }
      if (complete.existsSync()) {
        request.response.write(
          jsonEncode({'status': 'registered', 'baselineId': id}),
        );
        return true;
      }
      if (!metaFile.existsSync()) {
        request.response.statusCode = 404;
        return true;
      }
      final m = validate(jsonDecode(metaFile.readAsStringSync()));
      final size = m['packageSize'] as int;
      final count = (size + chunkSize - 1) ~/ chunkSize;
      if (match![3] != null) {
        final index = int.parse(match[3]!);
        if (index >= count) throw const FormatException('chunk index');
        final bytes = await readBody(request, chunkSize);
        final expected = index == count - 1
            ? size - index * chunkSize
            : chunkSize;
        if (bytes.length != expected)
          throw const FormatException('chunk length');
        final chunk = File('${pending.path}/$index.chunk');
        if (chunk.existsSync() &&
            sha256.convert(chunk.readAsBytesSync()) != sha256.convert(bytes)) {
          request.response.statusCode = 409;
          return true;
        }
        final tmp = File('${chunk.path}.tmp')
          ..writeAsBytesSync(bytes, flush: true);
        tmp.renameSync(chunk.path);
        request.response.write(
          jsonEncode({'status': 'staged', 'index': index}),
        );
        return true;
      }
      await readBody(request, 0);
      final extension = m['platform'] == 'ios' ? 'ipa' : 'apk';
      final package = File('${pending.path}/app.$extension');
      final output = package.openWrite();
      try {
        for (var i = 0; i < count; i++) {
          final chunk = File('${pending.path}/$i.chunk');
          if (!chunk.existsSync()) throw const FormatException('missing chunk');
          await output.addStream(chunk.openRead());
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (await package.length() != size ||
          (await sha256.bind(package.openRead()).first).toString() !=
              m['packageSha256']) {
        throw const FormatException('package hash');
      }
      final url = await storeFile(package, m['packageSha256'], size);
      if (url.scheme != 'https') throw StateError('HTTPS package URL required');
      final record = {
        ...m,
        'packageUrl': url.toString(),
        'registeredAt': DateTime.now().toUtc().toIso8601String(),
      };
      final tmp = File('${complete.path}.tmp')
        ..writeAsStringSync(jsonEncode(record), flush: true);
      tmp.renameSync(complete.path);
      // Only this completed upload's generated staging files are removed.
      await pending.delete(recursive: true);
      request.response.statusCode = 201;
      request.response.write(
        jsonEncode({'status': 'registered', 'baselineId': id}),
      );
      return true;
    } finally {
      busy.remove(id);
    }
  }
}
