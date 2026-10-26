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
    final artifact = File('${temp.path}/patch.bytecode')
      ..writeAsBytesSync([1, 2, 3, 4]);
    final envelope = File('${temp.path}/manifest.json');
    await sign(['sign', keys, artifact.path, envelope.path, baseline]);
    final publicKeys = {
      'spike-p256-1': base64.decode(
        File('$keys/public-key.txt').readAsStringSync(),
      ),
    };
    const token = 'test-only-publish-token-placeholder';
    const uploadToken = 'test-only-upload-token-placeholder';
    var storageUnavailable = false;
    service = DeliveryServer(
      Directory('${temp.path}/server'),
      token,
      publicKeys,
      uploadToken: uploadToken,
      storeArtifact: (_, __) async {
        if (storageUnavailable) throw StateError('storage/CDN unavailable');
      },
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
    final uploadHeaders = {
      'authorization': 'Bearer $uploadToken',
      'content-type': 'application/json',
    };
    storageUnavailable = true;
    require(
      (await network.post(
            origin.resolve('/v1/uploads'),
            headers: uploadHeaders,
            body: body,
          )).statusCode ==
          500,
      'failed external storage accepted an upload',
    );
    final emptyInventory = await network.get(
      origin.resolve('/v1/uploads'),
      headers: headers,
    );
    require(
      (jsonDecode(emptyInventory.body) as List).isEmpty,
      'failed external upload entered inventory',
    );
    storageUnavailable = false;
    for (var attempt = 0; attempt < 2; attempt++) {
      require(
        (await network.post(
              origin.resolve('/v1/uploads'),
              headers: uploadHeaders,
              body: body,
            )).statusCode ==
            201,
        'signed upload or idempotent retry failed',
      );
    }
    require(
      await updates.checkAndDownload() == 'no_update',
      'upload unexpectedly published a patch',
    );
    final uploadCli = File.fromUri(
      Platform.script,
    ).parent.parent.parent.parent.uri.resolve('tool/upload_patch.py');
    final cliResult = await Process.run(
      'python3',
      [
        '-B',
        uploadCli.toFilePath(),
        origin.toString(),
        temp.path,
        '--dev-loopback',
      ],
      environment: {'HOTFIX_UPLOAD_TOKEN': uploadToken},
    );
    require(
      cliResult.exitCode == 0,
      'local upload CLI failed: ${cliResult.stderr}',
    );
    require(
      await updates.checkAndDownload() == 'no_update',
      'CLI upload unexpectedly published a patch',
    );
    require(
      (await network.post(
            origin.resolve('/v1/releases'),
            headers: uploadHeaders,
            body: body,
          )).statusCode ==
          401,
      'upload credential published a patch',
    );
    final invalidStaging = jsonDecode(body) as Map<String, dynamic>;
    invalidStaging['artifact'] = base64.encode([99]);
    require(
      (await network.post(
            origin.resolve('/v1/uploads'),
            headers: uploadHeaders,
            body: jsonEncode(invalidStaging),
          )).statusCode ==
          422,
      'upload accepted corrupt bytes',
    );
    final stagedManifest =
        (jsonDecode(envelope.readAsStringSync()) as Map)['manifest'] as Map;
    final activation = jsonEncode({
      'baselineId': baseline,
      'patchId': stagedManifest['patchId'],
      'kind': 'candidate',
    });
    require(
      (await network.get(
            origin.resolve('/v1/uploads'),
            headers: uploadHeaders,
          )).statusCode ==
          401,
      'upload credential read management inventory',
    );
    final inventory = await network.get(
      origin.resolve('/v1/uploads'),
      headers: headers,
    );
    require(
      inventory.statusCode == 200 &&
          (jsonDecode(inventory.body) as List).single['status'] == 'uploaded',
      'staged inventory missing',
    );
    require(
      (await network.post(
            origin.resolve('/v1/activate'),
            headers: uploadHeaders,
            body: activation,
          )).statusCode ==
          401,
      'uploader activated a staged patch',
    );
    storageUnavailable = true;
    require(
      (await network.post(
            origin.resolve('/v1/activate'),
            headers: headers,
            body: activation,
          )).statusCode ==
          500,
      'CDN failure did not block publication',
    );
    require(
      await updates.checkAndDownload() == 'no_update',
      'failed publication changed release pointer',
    );
    storageUnavailable = false;
    require(
      (await network.post(
            origin.resolve('/v1/activate'),
            headers: headers,
            body: activation,
          )).statusCode ==
          201,
      'signed staged publication failed',
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
    Future<List<int>> policy(
      int rollout,
      bool revoke, {
      String? baselineId,
      String? patchId,
    }) async {
      final payload = Map<String, dynamic>.from(
        (jsonDecode(envelope.readAsStringSync()) as Map)['manifest'] as Map,
      );
      policyTime = policyTime.add(const Duration(seconds: 1));
      payload['issuedAt'] = '${policyTime.toIso8601String().split('.').first}Z';
      payload['rolloutPercent'] = rollout;
      payload['revoked'] = revoke;
      if (baselineId != null) payload['baselineId'] = baselineId;
      if (patchId != null) payload['patchId'] = patchId;
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
    final historyBaseline = 'c' * 64;
    final p1 = await policy(
      100,
      false,
      baselineId: historyBaseline,
      patchId: 'p1',
    );
    final p2 = await policy(
      100,
      false,
      baselineId: historyBaseline,
      patchId: 'p2',
    );
    require(await publishPolicy(p1) == 201, 'history P1 publication');
    require(await publishPolicy(p2) == 201, 'history P2 publication');
    final withdrawP1 = await policy(
      0,
      true,
      baselineId: historyBaseline,
      patchId: 'p1',
    );
    require(await publishPolicy(withdrawP1) == 201, 'historical P1 withdrawal');
    require(
      await publishPolicy(withdrawP1) == 201,
      'historical P1 withdrawal retry',
    );
    final checkUri = origin
        .resolve('/v1/check')
        .replace(queryParameters: {'baselineId': historyBaseline});
    require(
      base64.encode((await network.get(checkUri)).bodyBytes) ==
          base64.encode(p2),
      'historical withdrawal replaced current P2 distribution',
    );
    final historyVerifier = SignedManifestVerifier(
      baselineId: historyBaseline,
      releaseIdentity: releaseIdentity,
      publicKeys: publicKeys,
    );
    final freshLoader = SignedPatchLoader(
      root: Directory('${temp.path}/history-client'),
      verifier: historyVerifier,
    );
    try {
      final freshUpdates = UpdateClient(
        freshLoader,
        origin,
        allowDevelopmentHttp: true,
      );
      require(
        await freshUpdates.checkAndDownload() == 'downloaded' &&
            freshLoader.store.readVerified('p2') != null,
        'fresh client could not download P2 after historical P1 withdrawal',
      );
      final withdrawP2 = await policy(
        0,
        true,
        baselineId: historyBaseline,
        patchId: 'p2',
      );
      require(await publishPolicy(withdrawP2) == 201, 'current P2 withdrawal');
      require(
        await publishPolicy(withdrawP2) == 201,
        'current P2 withdrawal retry',
      );
      require(
        historyVerifier.verify((await network.get(checkUri)).bodyBytes) ==
                null &&
            await freshUpdates.checkAndDownload() == 'withdrawn' &&
            freshLoader.store.readVerified('p2') == null,
        'current withdrawal left P2 available',
      );
      final withdrawals =
          jsonDecode(
                (await network.get(
                  origin
                      .resolve('/v1/withdrawals')
                      .replace(
                        queryParameters: {'baselineId': historyBaseline},
                      ),
                )).body,
              )
              as List;
      final withdrawnIds = withdrawals
          .map(
            (encoded) => historyVerifier
                .verify(base64.decode(encoded as String), allowRevocation: true)
                ?.patchId,
          )
          .toSet();
      require(
        withdrawals.length == 2 && withdrawnIds.containsAll(['p1', 'p2']),
        'withdrawal feed lost a signed policy or duplicated a retry',
      );
    } finally {
      freshLoader.close();
    }
    print(
      'PASS: historical withdrawal preserves current patch; current withdrawal stops distribution',
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
    // Hosted API prefixes must survive routing; bytes may come from a separate CDN.
    final apiPaths = <String>[];
    final cdnPaths = <String>[];
    final prefixed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    prefixed.listen((request) async {
      apiPaths.add(request.uri.path);
      await request.drain<void>();
      switch (request.uri.path) {
        case '/public/hotfix-test/v1/withdrawals':
          request.response.write('[]');
        case '/public/hotfix-test/v1/check':
          request.response.add(envelope.readAsBytesSync());
        case '/public/hotfix-test/v1/reports':
          request.response.statusCode = 202;
        default:
          request.response.statusCode = 404;
      }
      await request.response.close();
    });
    cdn.listen((request) async {
      cdnPaths.add(request.uri.path);
      request.response.add(artifact.readAsBytesSync());
      await request.response.close();
    });
    final hostedLoader = SignedPatchLoader(
      root: Directory('${temp.path}/hosted-client'),
      verifier: verifier,
    );
    try {
      for (final suffix in ['', '/']) {
        final hosted = UpdateClient(
          hostedLoader,
          Uri.parse(
            'http://127.0.0.1:${prefixed.port}/public/hotfix-test$suffix',
          ),
          artifactBase: Uri.parse(
            'http://127.0.0.1:${cdn.port}/objects/v1/blobs/',
          ),
          allowDevelopmentHttp: true,
        );
        require(
          await hosted.checkAndDownload() == 'downloaded',
          'hosted download',
        );
        require(
          await hosted.report('baseline_healthy', null),
          'prefixed report',
        );
      }
      require(
        apiPaths.every((p) => p.startsWith('/public/hotfix-test/v1/')),
        'API prefix lost',
      );
      require(
        cdnPaths.length == 2 &&
            cdnPaths.every(
              (p) =>
                  p ==
                  '/objects/v1/blobs/${verifier.verify(envelope.readAsBytesSync())!.artifactSha256}',
            ),
        'artifact not fetched from configured CDN',
      );
      for (final invalid in [
        'http://example.com/blobs/',
        'https://user:secret@example.com/blobs/',
        'https://example.com/blobs',
        'https://example.com/blobs/?token=x',
      ]) {
        var rejected = false;
        try {
          UpdateClient(
            hostedLoader,
            Uri.parse('https://example.com/api'),
            artifactBase: Uri.parse(invalid),
          );
        } on ArgumentError {
          rejected = true;
        }
        require(rejected, 'unsafe CDN configuration accepted');
      }
    } finally {
      hostedLoader.close();
      await prefixed.close(force: true);
      await cdn.close(force: true);
    }
    print(
      'PASS: prefixed API and separate CDN preserve signed downloads and reports',
    );
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
