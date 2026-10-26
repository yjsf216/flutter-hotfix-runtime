import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'delivery_server.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final temp = Directory.systemTemp.createTempSync('upload-inventory-check.');
  final network = http.Client();
  const admin = 'test-admin-token-12345678901234567890';
  const upload = 'test-upload-token-1234567890123456789';
  final headers = {'authorization': 'Bearer $admin'};
  final uploadHeaders = {'authorization': 'Bearer $upload'};
  final baseline = 'a' * 64;
  final signer = File.fromUri(
    Platform.script,
  ).parent.uri.resolve('signature_check.dart');
  DeliveryServer? service;
  Completer<void>? storageEntered;
  Completer<void>? storageRelease;
  var stores = 0;
  Future<void> sign(List<String> args) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      '-DHOTFIX_PATCH_NUMBER=1',
      signer.toFilePath(),
      ...args,
    ]);
    check(result.exitCode == 0, 'sign: ${result.stderr}');
  }

  try {
    final keys = '${temp.path}/keys';
    await sign(['keygen', keys]);
    final artifact = File('${temp.path}/patch.bytecode')
      ..writeAsBytesSync([1, 2, 3]);
    final signed = File('${temp.path}/manifest.json');
    await sign(['sign', keys, artifact.path, signed.path, baseline, 'p1']);
    final envelope = jsonDecode(signed.readAsStringSync()) as Map;
    final manifest = envelope['manifest'] as Map;
    final body = jsonEncode({
      'envelope': base64.encode(signed.readAsBytesSync()),
      'artifact': base64.encode(artifact.readAsBytesSync()),
    });
    final publicKeys = {
      'spike-p256-1': base64.decode(
        File('$keys/public-key.txt').readAsStringSync(),
      ),
    };
    final root = Directory('${temp.path}/server');
    DeliveryServer create() => DeliveryServer(
      root,
      admin,
      publicKeys,
      uploadToken: upload,
      storeArtifact: (_, __) async {
        stores++;
        if (storageRelease != null) {
          storageEntered!.complete();
          await storageRelease.future;
        }
      },
    );
    service = create();
    await service.start(port: 0);
    final origin = Uri.parse('http://127.0.0.1:${service.server!.port}');
    Future<http.Response> post(
      String path,
      String body, [
      bool uploader = false,
    ]) => network.post(
      origin.resolve(path),
      headers: uploader ? uploadHeaders : headers,
      body: body,
    );
    Future<List> list([bool deleted = false]) async =>
        jsonDecode(
              (await network.get(
                origin.resolve(
                  '/v1/uploads${deleted ? '?includeDeleted=1' : ''}',
                ),
                headers: headers,
              )).body,
            )
            as List;
    final action = '/v1/uploads/$baseline/p1';
    final activation = jsonEncode({
      'baselineId': baseline,
      'patchId': 'p1',
      'kind': 'candidate',
    });
    check((await post('/v1/uploads', body, true)).statusCode == 201, 'upload');
    final firstTime = (await list()).single['uploadedAt'];
    check(DateTime.tryParse(firstTime) != null, 'missing upload date');
    check(
      (await post('/v1/uploads', body, true)).statusCode == 201 &&
          (await list()).single['uploadedAt'] == firstTime,
      'retry changed upload time',
    );
    final candidate = File('${root.path}/$baseline.p1.candidate');
    final candidateBytes = candidate.readAsStringSync();
    final ledger = File('${root.path}/$baseline.numbers').readAsStringSync();
    final blob = File('${root.path}/${manifest['artifactSha256']}.blob');
    // Simulate an older deployment without timestamp metadata, using a signed fixture.
    final olderBaseline = 'b' * 64;
    final older = File('${temp.path}/older.json');
    await sign(['sign', keys, artifact.path, older.path, olderBaseline, 'p1']);
    final legacy = File('${root.path}/$olderBaseline.p1.candidate')
      ..writeAsBytesSync(older.readAsBytesSync())
      ..setLastModifiedSync(DateTime.utc(2020));
    check(
      (await list()).first['manifest']['baselineId'] == baseline &&
          (await list()).last['uploadedAt'].startsWith('2020-01-01'),
      'legacy time/order',
    );
    check(
      (await post('$action/delete', '{}', true)).statusCode == 401,
      'uploader deleted',
    );
    check(
      (await post('$action/restore', '{}', true)).statusCode == 401,
      'uploader restored',
    );
    check(
      (await post('$action/delete', '{"force":true}')).statusCode == 400,
      'unexpected body',
    );
    check(
      (await post('/v1/uploads/${'c' * 64}/p1/delete', '{}')).statusCode == 404,
      'unknown target',
    );
    final storesBefore = stores;
    check((await post('$action/delete', '{}')).statusCode == 200, 'delete');
    final deletedAt = (await list(true)).first['deletedAt'];
    check(
      (await post('$action/delete', '')).statusCode == 200 &&
          (await list(true)).first['deletedAt'] == deletedAt,
      'delete retry',
    );
    check(
      (await list()).length == 1 &&
          (await list()).single['manifest']['baselineId'] == olderBaseline,
      'delete affected wrong record',
    );
    check(
      stores == storesBefore &&
          blob.readAsBytesSync().join() == '123' &&
          candidate.readAsStringSync() == candidateBytes &&
          File('${root.path}/$baseline.numbers').readAsStringSync() == ledger,
      'delete changed storage/number',
    );
    check(
      (await post('/v1/activate', activation)).statusCode == 409,
      'activated deleted',
    );
    check(
      (await post('/v1/releases', body)).statusCode == 409,
      'legacy API published deleted',
    );
    check(
      (await post('/v1/uploads', body, true)).statusCode == 201 &&
          (await list()).length == 1,
      'upload restored deleted',
    );
    await service.server!.close(force: true);
    service = create();
    await service.start(port: origin.port);
    check((await list()).length == 1, 'restart lost tombstone');
    check(
      (await post('$action/restore', '{}')).statusCode == 200 &&
          (await list()).first['uploadedAt'] == firstTime,
      'restore changed date',
    );
    check(
      (await post('$action/restore', '')).statusCode == 200,
      'restore retry',
    );
    // Deletion racing an external CDN operation must win before release commit.
    storageEntered = Completer<void>();
    storageRelease = Completer<void>();
    final publishing = post('/v1/activate', activation);
    await storageEntered.future.timeout(const Duration(seconds: 10));
    check(
      (await post('$action/delete', '{}')).statusCode == 200,
      'delete during CDN wait',
    );
    storageRelease.complete();
    check(
      (await publishing).statusCode == 409,
      'publication race bypassed deletion',
    );
    storageRelease = null;
    check(
      (await network.get(
            origin.resolve('/v1/check?baselineId=$baseline'),
          )).body ==
          'null',
      'deleted patch distributed',
    );
    await post('$action/restore', '{}');
    check(
      (await post('/v1/activate', activation)).statusCode == 201,
      'publish after restore',
    );
    check(
      (await post('$action/delete', '{}')).statusCode == 409 &&
          (await list()).first['status'] == 'published',
      'published patch deleted',
    );
    final withdrawalInput = File('${temp.path}/withdrawal-input.json')
      ..writeAsStringSync(
        jsonEncode({
          ...manifest,
          'revoked': true,
          'rolloutPercent': 0,
          'issuedAt':
              '${DateTime.now().toUtc().toIso8601String().split('.').first}Z',
        }),
      );
    final withdrawal = File('${temp.path}/withdrawal.json');
    await sign(['sign-json', keys, withdrawalInput.path, withdrawal.path]);
    check(
      (await post(
            '/v1/releases',
            jsonEncode({
              'envelope': base64.encode(withdrawal.readAsBytesSync()),
              'artifact': base64.encode(artifact.readAsBytesSync()),
            }),
          )).statusCode ==
          201,
      'withdraw',
    );
    final policies = File(
      '${root.path}/$baseline.withdrawals',
    ).readAsStringSync();
    check(
      (await post('$action/delete', '{}')).statusCode == 200,
      'withdrawn deletion',
    );
    check(
      (await post('$action/restore', '{}')).statusCode == 200 &&
          (await list()).first['status'] == 'withdrawn' &&
          (await post('/v1/activate', activation)).statusCode == 409,
      'restore undid withdrawal',
    );
    check(
      File('${root.path}/$baseline.withdrawals').readAsStringSync() ==
              policies &&
          legacy.existsSync(),
      'delete/restore changed policy or other record',
    );
    print(
      'PASS: upload timestamps/order, legacy fallback, auth, reversible deletion, restart, immutable storage/number, publication race and withdrawal safety',
    );
  } finally {
    if (storageRelease != null && !storageRelease.isCompleted) {
      storageRelease.complete();
    }
    await service?.server?.close(force: true);
    network.close();
    temp.deleteSync(recursive: true);
  }
}
