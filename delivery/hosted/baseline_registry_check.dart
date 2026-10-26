import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import '../../spikes/patch_ir_spike/tool/delivery_server.dart';
import 'baseline_registry.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final root = Directory.systemTemp.createTempSync('baseline-registry-check.');
  final client = HttpClient();
  const admin = 'admin-test-token-123456789012345678';
  const upload = 'upload-test-token-123456789012345678';
  var unavailable = false;
  var stored = 0;
  var registry = BaselineRegistry(root, admin, upload, (
    file,
    hash,
    size,
  ) async {
    check(await file.length() == size, 'store size');
    check(
      (await sha256.bind(file.openRead()).first).toString() == hash,
      'store hash',
    );
    if (unavailable) throw StateError('storage offline');
    stored++;
    return Uri.parse('https://cdn.example.com/$hash');
  });
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      if (!await registry.handle(request)) request.response.statusCode = 404;
    } on FormatException {
      request.response.statusCode = 400;
    } catch (_) {
      request.response.statusCode = 500;
    }
    await request.response.close();
  });
  Future<(int, dynamic)> call(
    String method,
    String path,
    String token, [
    List<int>? body,
  ]) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}/v1/baselines$path'),
    );
    request.headers.set('authorization', 'Bearer $token');
    if (body != null) request.add(body);
    final response = await request.close();
    final bytes = await readBody(response, 65536);
    return (
      response.statusCode,
      bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes)),
    );
  }

  try {
    final bytes = List<int>.filled(BaselineRegistry.chunkSize + 3, 7);
    final id = 'a' * 64;
    final metadata = {
      'baselineId': id,
      'appId': 'com.example.app',
      'platform': 'android',
      'release': '1.2.3+4',
      'gitCommit': 'b' * 40,
      'sourceCommit': 'c' * 40,
      'sourceBranch': 'release/1.2.3',
      'packageSize': bytes.length,
      'packageSha256': sha256.convert(bytes).toString(),
    };
    final body = utf8.encode(jsonEncode(metadata));
    check(registry.validate({...metadata, 'abi': 'arm'})['abi'] == 'arm', 'ARM32 metadata rejected');
    check(!registry.validate(metadata).containsKey('abi'), 'Legacy metadata changed during normalization');
    for (final invalid in [
      {...metadata, 'abi': 'x86'},
      {...metadata, 'platform': 'ios', 'abi': 'arm'},
    ]) {
      var rejected = false;
      try { registry.validate(invalid); } on FormatException { rejected = true; }
      check(rejected, 'unsupported ABI accepted');
    }
    check(
      (await call('POST', '', admin, body)).$1 == 401,
      'admin cannot upload',
    );
    check((await call('GET', '', upload)).$1 == 401, 'upload cannot list');
    check(
      (await call('POST', '', upload, body)).$2['status'] == 'staging',
      'stage',
    );
    check(
      (await call('GET', '', admin)).$2.isEmpty,
      'incomplete baseline exposed',
    );
    check(
      (await call('POST', '/$id/finish', upload)).$1 == 400,
      'missing chunks',
    );
    check(
      (await call('POST', '/$id/chunks/0', upload, [7])).$1 == 400,
      'short chunk',
    );
    final first = bytes.sublist(0, BaselineRegistry.chunkSize);
    check(
      (await call('POST', '/$id/chunks/0', upload, first)).$1 == 200,
      'first',
    );
    check(
      (await call('POST', '/$id/chunks/0', upload, first)).$1 == 200,
      'retry',
    );
    check(
      (await call(
            'POST',
            '/$id/chunks/0',
            upload,
            List.filled(first.length, 8),
          )).$1 ==
          409,
      'overwrite',
    );
    check(
      (await call('POST', '/$id/chunks/1', upload, [7, 7, 7])).$1 == 200,
      'last',
    );
    unavailable = true;
    check((await call('POST', '/$id/finish', upload)).$1 == 500, 'CDN outage');
    check((await call('GET', '', admin)).$2.isEmpty, 'failed CDN exposed');
    unavailable = false;
    check((await call('POST', '/$id/finish', upload)).$1 == 201, 'complete');
    check(
      (await call('POST', '', upload, body)).$2['status'] == 'registered',
      'registration retry',
    );
    final changed = {...metadata, 'release': '9.9.9+9'};
    check(
      (await call('POST', '', upload, utf8.encode(jsonEncode(changed)))).$1 ==
          409,
      'immutable metadata',
    );
    final list = (await call('GET', '', admin)).$2 as List;
    check(
      list.length == 1 && list.single['packageUrl'].startsWith('https://'),
      'listing',
    );
    check(
      stored == 1 && !Directory('${root.path}/$id.pending').existsSync(),
      'cleanup/idempotency',
    );
    final complete = File('${root.path}/$id.json');
    final original = complete.readAsStringSync();
    final olderId = 'd' * 64;
    final older = File('${root.path}/$olderId.json')
      ..writeAsStringSync(
        jsonEncode({
          ...list.single as Map,
          'baselineId': olderId,
          'registeredAt': '2020-01-01T00:00:00Z',
        }),
      );
    final olderBytes = older.readAsStringSync();
    check(
      (await call('GET', '', admin)).$2.first['baselineId'] == id,
      'newest upload first',
    );
    check(
      (await call('POST', '/$id/delete', upload)).$1 == 401,
      'upload role deleted baseline',
    );
    check(
      (await call(
            'POST',
            '/$id/delete',
            admin,
            utf8.encode('{"force":true}'),
          )).$1 ==
          400,
      'unexpected delete option accepted',
    );
    check(
      (await call('POST', '/${'f' * 64}/delete', admin)).$1 == 404,
      'missing baseline deleted',
    );
    check(
      (await call(
            'POST',
            '/$id/delete',
            admin,
            utf8.encode('{}'),
          )).$2['status'] ==
          'deleted',
      'delete',
    );
    final deletedAt = File('${root.path}/$id.deleted').readAsStringSync();
    check(
      (await call('POST', '/$id/delete', admin)).$1 == 200 &&
          File('${root.path}/$id.deleted').readAsStringSync() == deletedAt,
      'delete retry changed timestamp',
    );
    final active = (await call('GET', '', admin)).$2 as List;
    check(
      active.length == 1 && active.single['baselineId'] == olderId,
      'default list did not hide only target',
    );
    final withDeleted =
        (await call('GET', '?includeDeleted=1', admin)).$2 as List;
    check(
      withDeleted.length == 2 && withDeleted.first['deletedAt'] == deletedAt,
      'deleted list',
    );
    check(
      (await call('POST', '', upload, body)).$2['status'] == 'registered' &&
          (await call('GET', '', admin)).$2.length == 1,
      'upload resurrected deleted record',
    );
    registry = BaselineRegistry(root, admin, upload, (_, __, ___) async {
      throw StateError('Deleting/restoring must not touch object storage');
    });
    check(
      (await call('GET', '', admin)).$2.length == 1,
      'deletion lost after restart',
    );
    check(
      (await call('POST', '/$id/restore', upload)).$1 == 401,
      'upload role restored baseline',
    );
    check(
      (await call('POST', '/$id/restore', admin)).$2['status'] == 'restored',
      'restore',
    );
    check(
      (await call('POST', '/$id/restore', admin)).$1 == 200,
      'restore retry',
    );
    final restored = (await call('GET', '', admin)).$2 as List;
    check(
      restored.length == 2 && !restored.first.containsKey('deletedAt'),
      'restored listing',
    );
    check(
      complete.readAsStringSync() == original &&
          older.readAsStringSync() == olderBytes &&
          stored == 1,
      'baseline metadata, another record or object storage changed',
    );
    print(
      'PASS: baseline roles, chunk retry/conflict, completeness, CDN failure, immutable registration',
    );
    print(
      'PASS: newest ordering, admin-only recoverable deletion, idempotency, restart and immutable metadata',
    );
  } finally {
    client.close(force: true);
    await server.close(force: true);
    root.deleteSync(recursive: true);
  }
}
