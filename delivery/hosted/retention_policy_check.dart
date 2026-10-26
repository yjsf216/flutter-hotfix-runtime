import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../../spikes/patch_ir_spike/tool/delivery_server.dart';
import 'retention_policy.dart';
import 'baseline_registry.dart';
import 'artifact_retirement.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final root = Directory.systemTemp.createTempSync('retention-check.');
  final client = HttpClient();
  const admin = 'admin-test-token-123456789012345678';
  const upload = 'upload-test-token-123456789012345678';
  var now = DateTime.utc(2026, 1, 1);
  void baseline(String id, String platform, String hash) {
    final file = File('${root.path}/baselines/$id.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({
        'baselineId': id,
        'appId': 'example.app',
        'platform': platform,
        'release': '1.0.0+1',
        'packageSha256': hash,
        'packageUrl': 'https://cdn.example.invalid/$hash',
        'registeredAt': now.toIso8601String(),
      }),
    );
  }

  final a = 'a' * 64,
      b = 'b' * 64,
      c = 'c' * 64,
      d = 'd' * 64,
      legacy = 'e' * 64;
  final unique = '1' * 64, shared = '2' * 64;
  baseline(a, 'android', unique);
  now = now.add(const Duration(minutes: 1));
  baseline(b, 'android', shared);
  now = now.add(const Duration(minutes: 1));
  baseline(c, 'android', '3' * 64);
  baseline(d, 'ios', '4' * 64);
  baseline(legacy, 'android', '5' * 64);
  var policy = RetentionPolicy(root, admin, upload, clock: () => now);
  policy.register(
    c,
    'main',
  ); // Delayed registration must not make an old upload newest.
  policy.register(a, 'main');
  policy.register(b, 'main');
  policy.register(d, 'main');
  check(
    !policy.retired(a) && policy.plan().single == a,
    'disabled policy changed baseline availability',
  );
  check(!policy.records.containsKey(legacy), 'legacy baseline adopted');
  var failPurge = true;
  List<String> purged = [];
  policy = RetentionPolicy(
    root,
    admin,
    upload,
    enabled: true,
    clock: () => now,
    purgeArtifacts: (hashes) async {
      if (failPurge) throw StateError('CDN unavailable');
      purged = hashes;
    },
  );
  // Protect an in-progress build while the third baseline becomes available.
  policy.leases['fixture'] = {
    'baselineId': a,
    'expiresAt': now.add(const Duration(minutes: 15)).toIso8601String(),
  };
  policy.reconcile();
  check(!policy.retired(a), 'active lease retired');
  now = now.add(const Duration(minutes: 16));
  policy.reconcile();
  check(
    policy.retired(a) &&
        !policy.retired(b) &&
        !policy.retired(c) &&
        !policy.retired(d),
    'wrong retention group',
  );
  File('${root.path}/$a.latest').writeAsStringSync('{"old":true}');
  File('${root.path}/$unique.blob').writeAsStringSync('old');
  File('${root.path}/$shared.blob').writeAsStringSync('shared');
  File('${root.path}/$a.p1.candidate').writeAsStringSync(
    jsonEncode({
      'manifest': {'baselineId': a, 'patchId': 'p1', 'artifactSha256': shared},
    }),
  );
  try {
    await policy.cleanup();
    throw StateError('cleanup failure ignored');
  } catch (_) {
    check(
      policy.records[a]['cleanupStatus'] == 'pending',
      'failed purge marked complete',
    );
  }
  failPurge = false;
  await policy.cleanup();
  check(
    purged.contains(unique) && !purged.contains(shared),
    'shared digest deleted',
  );
  check(
    !File('${root.path}/$unique.blob').existsSync() &&
        File('${root.path}/$shared.blob').existsSync(),
    'wrong local blob removed',
  );
  check(
    policy.records[a]['cleanupStatus'] == 'complete',
    'cleanup completion missing',
  );
  final registry = BaselineRegistry(
    Directory('${root.path}/baselines'),
    admin,
    upload,
    (_, hash, __) async => Uri.parse('https://cdn.example.invalid/$hash'),
    isRetired: policy.retired,
  );
  final server = DeliveryServer(
    root,
    admin,
    {'test': Uint8List(65)},
    uploadToken: upload,
    isRetired: policy.retired,
    isBlobRetired: policy.blockedBlob,
    mutationGate: SerialMutations().run,
    extraRoute: (r) async => await policy.handle(r) || await registry.handle(r),
  );
  await server.start(port: 0);
  Future<(int, dynamic)> call(
    String method,
    String path, [
    Map? body,
    String? token,
  ]) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.server!.port}$path'),
    );
    if (token != null) request.headers.set('authorization', 'Bearer $token');
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final bytes = await readBody(response, 65536);
    return (
      response.statusCode,
      bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes)),
    );
  }

  try {
    check(
      (await call('GET', '/v1/check?baselineId=$a')).$2 == null,
      'retired update exposed',
    );
    check(
      (await call('GET', '/v1/blobs/$unique')).$1 == 410,
      'retired blob exposed',
    );
    check(
      (await call('GET', '/v1/uploads', null, admin)).$2.isEmpty,
      'retired patch listed',
    );
    final rows = (await call('GET', '/v1/baselines', null, admin)).$2 as List;
    check(
      rows.length == 4 && rows.every((r) => r['baselineId'] != a),
      'baseline filtering/legacy preservation',
    );
    check(
      (await call('POST', '/v1/patch-numbers', {
            'baselineId': a,
            'patchId': 'p2',
          }, upload)).$1 ==
          410,
      'retired number assigned',
    );
    check(
      (await call('POST', '/v1/baselines/$a/restore', {}, admin)).$1 == 410,
      'retired baseline restored',
    );
    check(
      (await call('GET', '/v1/retention')).$1 == 401,
      'retention metadata public',
    );
    check(
      (await call('POST', '/v1/retention/cleanup', {}, upload)).$1 == 403,
      'uploader can delete objects',
    );
    final lease = await call('POST', '/v1/retention/lease', {
      'baselineId': b,
      'action': 'acquire',
    }, upload);
    check(lease.$1 == 200 && policy.inUse(b), 'lease acquire');
    check(
      (await call('POST', '/v1/retention/lease', {
            'baselineId': b,
            'action': 'release',
            'token': 'wrong',
          }, upload)).$1 ==
          409,
      'lease stolen',
    );
    check(
      (await call('POST', '/v1/retention/lease', {
            'baselineId': b,
            'action': 'release',
            'token': lease.$2['token'],
          }, upload)).$1 ==
          200,
      'lease release',
    );
    final restarted = RetentionPolicy(root, admin, upload);
    check(restarted.retired(a), 'disable/restart resurrected old baseline');
    print(
      'PASS: default-off retention, group isolation, leases, durable retirement, shared blobs, cleanup failure, HTTP denial and legacy preservation',
    );
  } finally {
    await server.server!.close(force: true);
    client.close(force: true);
    root.deleteSync(recursive: true);
  }
}
