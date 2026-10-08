import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import '../dynamic_aot/release_identity.dart';
import '../signed_manifest.dart';
import '../signed_patch_loader.dart';
import '../update_client.dart';
import 'delivery_server.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final temp = Directory.systemTemp.createTempSync('hotfix-delivery-check.');
  final signer = File.fromUri(
    Platform.script,
  ).parent.uri.resolve('signature_check.dart');
  Future<void> sign(List<String> args) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      signer.toFilePath(),
      ...args,
    ]);
    require(result.exitCode == 0, 'test signer failed: ${result.stderr}');
  }

  DeliveryServer? service;
  final network = http.Client();
  try {
    final keys = '${temp.path}/keys';
    await sign(['keygen', keys]);
    final baseline = 'a' * 64;
    final artifact = File('${temp.path}/patch')..writeAsBytesSync([1, 2, 3, 4]);
    final envelope = File('${temp.path}/manifest.json');
    await sign(['sign', keys, artifact.path, envelope.path, baseline]);
    final publicKeys = {
      'spike-p256-1': base64.decode(
        File('$keys/public-key.txt').readAsStringSync(),
      ),
    };
    const token = 'test-only-publish-token-placeholder';
    service = DeliveryServer(
      Directory('${temp.path}/server'),
      token,
      publicKeys,
    );
    await service.start(port: 0);
    final origin = Uri.parse('http://127.0.0.1:${service.server!.port}');
    final verifier = SignedManifestVerifier(
      baselineId: baseline,
      releaseIdentity: releaseIdentity,
      publicKeys: publicKeys,
    );
    final root = Directory('${temp.path}/client');
    var loader = SignedPatchLoader(root: root, verifier: verifier);
    var updates = UpdateClient(loader, origin, allowDevelopmentHttp: true);
    require(await updates.checkAndDownload() == 'no_update', 'empty release');
    final body = jsonEncode({
      'envelope': base64.encode(envelope.readAsBytesSync()),
      'artifact': base64.encode(artifact.readAsBytesSync()),
    });
    require(
      (await network.post(
            origin.resolve('/v1/releases'),
            body: body,
          )).statusCode ==
          401,
      'unauthorized publisher accepted',
    );
    final headers = {
      'authorization': 'Bearer $token',
      'content-type': 'application/json',
    };
    require(
      (await network.post(
            origin.resolve('/v1/releases'),
            headers: headers,
            body: body,
          )).statusCode ==
          201,
      'signed publication failed',
    );
    // Identical retry is idempotent; a modified payload fails authentication.
    require(
      (await network.post(
            origin.resolve('/v1/releases'),
            headers: headers,
            body: body,
          )).statusCode ==
          201,
      'publish retry',
    );
    final corruptUpload = jsonDecode(body) as Map<String, dynamic>;
    corruptUpload['artifact'] = base64.encode([9]);
    require(
      (await network.post(
            origin.resolve('/v1/releases'),
            headers: headers,
            body: jsonEncode(corruptUpload),
          )).statusCode ==
          422,
      'corrupt upload accepted',
    );
    var activations = 0;
    require(
      await loader.load<void>((_) async {
            activations++;
          }, restoreBaseline: () {}) ==
          null,
      'clean baseline unexpectedly patched',
    );
    await updates.report('baseline_healthy', null);
    require(
      await updates.checkAndDownload() == 'downloaded' && activations == 0,
      'download must not activate during current boot',
    );
    loader.close();
    loader = SignedPatchLoader(root: root, verifier: verifier);
    final loaded = await loader.load<void>((bytes) async {
      require(
        base64.encode(bytes) == base64.encode(artifact.readAsBytesSync()),
        'changed bytes',
      );
      activations++;
    }, restoreBaseline: () {});
    require(
      loaded != null && loader.markHealthy(loaded) && activations == 1,
      'next-boot activation',
    );
    updates = UpdateClient(loader, origin, allowDevelopmentHttp: true);
    require(
      await updates.report('patch_healthy', loaded!.patchId),
      'health report',
    );
    require(
      await updates.checkAndDownload(runningPatchId: 'p1') == 'current',
      'current patch',
    );
    final stateBefore = File('${root.path}/state.json').readAsStringSync();
    final manifest = verifier.verify(envelope.readAsBytesSync())!;
    File(
      '${service.root.path}/${manifest.artifactSha256}.blob',
    ).writeAsBytesSync([0]);
    require(
      await updates.checkAndDownload() == 'rejected',
      'corrupt download accepted',
    );
    require(
      File('${root.path}/state.json').readAsStringSync() == stateBefore,
      'corruption changed LKG',
    );
    final invalid =
        jsonDecode(envelope.readAsStringSync()) as Map<String, Object?>;
    final signature = base64.decode(invalid['signature'] as String)..[30] ^= 1;
    invalid['signature'] = base64.encode(signature);
    File(
      '${service.root.path}/$baseline.latest',
    ).writeAsBytesSync(canonicalManifestBytes(invalid));
    require(
      await updates.checkAndDownload() == 'rejected',
      'bad signature accepted',
    );
    final wrong = File('${temp.path}/wrong.json');
    await sign(['sign', keys, artifact.path, wrong.path, 'b' * 64]);
    File(
      '${service.root.path}/$baseline.latest',
    ).writeAsBytesSync(wrong.readAsBytesSync());
    require(
      await updates.checkAndDownload() == 'rejected',
      'wrong baseline accepted',
    );
    require(
      File('${root.path}/state.json').readAsStringSync() == stateBefore,
      'rejection changed LKG',
    );
    final reports = File(
      '${service.root.path}/reports.jsonl',
    ).readAsLinesSync().map((line) => jsonDecode(line) as Map).toList();
    require(
      reports.any((r) => r['outcome'] == 'downloaded') &&
          reports.any((r) => r['outcome'] == 'patch_healthy'),
      'missing reports',
    );
    await service.server!.close(force: true);
    require(
      await updates.checkAndDownload() == 'download_failed',
      'offline should fail open',
    );
    require(
      File('${root.path}/state.json').readAsStringSync() == stateBefore,
      'offline changed LKG',
    );
    require(
      loader.store.pendingReports().isNotEmpty,
      'offline report not persisted',
    );
    loader.close();
    File(
      '${service.root.path}/reports.jsonl',
    ).writeAsStringSync('{"torn":', mode: FileMode.append);
    service = DeliveryServer(service.root, token, publicKeys);
    await service.start(port: origin.port);
    loader = SignedPatchLoader(root: root, verifier: verifier);
    updates = UpdateClient(loader, origin, allowDevelopmentHttp: true);
    await updates.flushReports();
    require(
      loader.store.pendingReports().isEmpty,
      'reports did not retry after restart',
    );
    final replay =
        jsonDecode(
              File('${service.root.path}/reports.jsonl').readAsLinesSync().last,
            )
            as Map;
    replay.remove('receivedAt');
    final lengthBefore = File(
      '${service.root.path}/reports.jsonl',
    ).lengthSync();
    require(
      (await network.post(
            origin.resolve('/v1/reports'),
            body: jsonEncode(replay),
          )).statusCode ==
          202,
      'idempotent report retry rejected',
    );
    require(
      File('${service.root.path}/reports.jsonl').lengthSync() == lengthBefore,
      'retry counted twice',
    );
    require(
      (await network.get(origin.resolve('/v1/stats'))).statusCode == 401,
      'unprotected statistics',
    );
    final stats = await network.get(
      origin.resolve('/v1/stats'),
      headers: headers,
    );
    require(
      stats.statusCode == 200 &&
          (jsonDecode(stats.body) as Map)['eventCounts'] is Map,
      'statistics unavailable',
    );

    // Restore authentic bytes after the negative downloads above.
    File(
      '${service.root.path}/${manifest.artifactSha256}.blob',
    ).writeAsBytesSync(artifact.readAsBytesSync());
    File(
      '${service.root.path}/$baseline.latest',
    ).writeAsBytesSync(envelope.readAsBytesSync());
    final pauseBody = jsonEncode({'baselineId': baseline, 'paused': true});
    require(
      (await network.post(
            origin.resolve('/v1/pause'),
            body: pauseBody,
          )).statusCode ==
          401,
      'unauthorized pause',
    );
    require(
      (await network.post(
            origin.resolve('/v1/pause'),
            headers: headers,
            body: pauseBody,
          )).statusCode ==
          204,
      'pause',
    );
    require(
      await updates.checkAndDownload() == 'no_update' &&
          loader.store.readVerified('p1') != null,
      'pause must not withdraw installed patch',
    );
    await network.post(
      origin.resolve('/v1/pause'),
      headers: headers,
      body: jsonEncode({'baselineId': baseline, 'paused': false}),
    );
    require(
      await updates.checkAndDownload(runningPatchId: 'p1') == 'current',
      'resume distribution',
    );

    var policyTime = DateTime.now().toUtc().subtract(
      const Duration(seconds: 20),
    );
    Future<List<int>> policy(int rollout, bool revoke) async {
      final payload = Map<String, dynamic>.from(
        (jsonDecode(envelope.readAsStringSync()) as Map)['manifest'] as Map,
      );
      policyTime = policyTime.add(const Duration(seconds: 1));
      payload['issuedAt'] = '${policyTime.toIso8601String().split('.').first}Z';
      payload['rolloutPercent'] = rollout;
      payload['revoked'] = revoke;
      final input = File('${temp.path}/policy-input.json')
        ..writeAsStringSync(jsonEncode(payload));
      final signed = File('${temp.path}/policy-signed.json');
      await sign(['sign-json', keys, input.path, signed.path]);
      return signed.readAsBytesSync();
    }

    Future<int> publishPolicy(List<int> bytes) async => (await network.post(
      origin.resolve('/v1/releases'),
      headers: headers,
      body: jsonEncode({
        'envelope': base64.encode(bytes),
        'artifact': base64.encode(artifact.readAsBytesSync()),
      }),
    )).statusCode;
    final bucket = loader.store.rolloutBucket(baseline, 'p1')!;
    require(
      bucket ==
          SignedPatchLoader(
            root: root,
            verifier: verifier,
          ).store.rolloutBucket(baseline, 'p1'),
      'rollout assignment changed after reopening',
    );
    final boundary = verifier.verify(
      Uint8List.fromList(await policy(bucket, false)),
    )!;
    final included = verifier.verify(
      Uint8List.fromList(await policy(bucket + 1, false)),
    )!;
    require(
      !loader.eligible(boundary) && loader.eligible(included),
      'partial rollout threshold',
    );
    require(
      await publishPolicy(await policy(0, false)) == 201,
      'signed zero-percent policy',
    );
    require(
      await updates.checkAndDownload() == 'not_selected',
      'zero-percent admitted',
    );
    require(
      await publishPolicy(await policy(100, false)) == 201,
      'rollout expansion',
    );
    require(
      await updates.checkAndDownload(runningPatchId: 'p1') == 'current',
      'full rollout',
    );
    require(
      await publishPolicy(await policy(0, true)) == 201,
      'signed withdrawal',
    );
    require(
      await updates.checkAndDownload(runningPatchId: 'p1') == 'withdrawn',
      'withdrawal not processed',
    );
    require(
      loader.store.readVerified('p1') == null,
      'withdrawn patch remained selectable',
    );
    require(
      await publishPolicy(await policy(100, false)) == 409,
      'revocation undone',
    );
    require(
      await publishPolicy(envelope.readAsBytesSync()) == 409,
      'old release replayed after withdrawal',
    );
    require(
      !loader.stage(envelope.path, artifact.path),
      'withdrawn ID reinstalled',
    );
    require(
      await loader.load<void>((_) async {
            throw StateError('withdrawn code executed');
          }, restoreBaseline: () {}) ==
          null,
      'withdrawn boot not bundled',
    );
    loader.close();
    print(
      'PASS: durable outbox/restart retry, event deduplication, authenticated statistics, pause/resume, sticky rollout, signed permanent withdrawal',
    );
    // Exercise a real interrupted response, not merely an offline connection.
    final flaky = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var downloads = 0;
    flaky.listen((request) async {
      if (request.uri.path == '/v1/withdrawals') {
        request.response.write('[]');
      } else if (request.uri.path == '/v1/check') {
        request.response.add(envelope.readAsBytesSync());
      } else if (request.uri.path.startsWith('/v1/blobs/')) {
        downloads++;
        if (downloads == 1) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.add(
            utf8.encode(
              'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n',
            ),
          );
          socket.add([1]);
          await socket.flush();
          await socket.close();
          socket.destroy();
          return;
        }
        request.response.add(artifact.readAsBytesSync());
      } else {
        request.response.statusCode = 202;
      }
      await request.response.close();
    });
    final retryLoader = SignedPatchLoader(
      root: Directory('${temp.path}/retry-client'),
      verifier: verifier,
    );
    try {
      final retryClient = UpdateClient(
        retryLoader,
        Uri.parse('http://127.0.0.1:${flaky.port}'),
        allowDevelopmentHttp: true,
      );
      require(
        await retryClient.checkAndDownload() == 'downloaded' && downloads == 2,
        'interrupted artifact was not retried as a complete verified file',
      );
    } finally {
      retryLoader.close();
      await flaky.close(force: true);
    }
    print('PASS: interrupted HTTP body retried from scratch before staging');
    print(
      'PASS: authenticated upload/storage -> check/download -> next boot -> health report',
    );
    print(
      'PASS: no-update, retries, corrupt upload/download, bad signature and offline preserve baseline/LKG',
    );
    print(
      'Scope: real loopback HTTP + store; module callback here is a test, not Flutter execution',
    );
  } finally {
    network.close();
    await service?.server?.close(force: true);
    temp.deleteSync(recursive: true);
  }
}
