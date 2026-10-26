import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../lib/signed_manifest.dart';
import '../lib/signed_patch_loader.dart';
import '../dynamic_aot/release_identity.dart';
import 'delivery_server.dart';

void check(bool value, String why) {
  if (!value) throw StateError(why);
}

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('patch-number-check.');
  final signer = File.fromUri(
    Platform.script,
  ).parent.uri.resolve('signature_check.dart').toFilePath();
  final network = http.Client();
  DeliveryServer? service;
  SignedPatchLoader? loader;
  Future<void> sign(List<String> args, [int? number]) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      if (number != null) '-DHOTFIX_PATCH_NUMBER=$number',
      signer,
      ...args,
    ]);
    check(result.exitCode == 0, 'sign failed: ${result.stderr}');
  }

  try {
    final keys = '${dir.path}/keys';
    await sign(['keygen', keys]);
    final baseline = 'a' * 64;
    final publicKeys = {
      'spike-p256-1': base64.decode(
        File('$keys/public-key.txt').readAsStringSync(),
      ),
    };
    const admin = 'admin-only-test-token-123456789';
    const upload = 'upload-only-test-token-123456789';
    final storage = Directory('${dir.path}/server');
    service = DeliveryServer(storage, admin, publicKeys, uploadToken: upload);
    await service.start(port: 0);
    var origin = Uri.parse('http://127.0.0.1:${service.server!.port}');
    Future<int> reserve(String id) async {
      final response = await network.post(
        origin.resolve('/v1/patch-numbers'),
        headers: {'authorization': 'Bearer $upload'},
        body: jsonEncode({'baselineId': baseline, 'patchId': id}),
      );
      check(response.statusCode == 200, 'reserve failed');
      return (jsonDecode(response.body) as Map)['patchNumber'] as int;
    }

    check(
      (await network.post(
            origin.resolve('/v1/patch-numbers'),
            headers: {'authorization': 'Bearer $admin'},
            body: '{}',
          )).statusCode ==
          401,
      'wrong role',
    );
    check(
      await reserve('one') == 1 && await reserve('one') == 1,
      'idempotency',
    );
    final next = await Future.wait([reserve('two'), reserve('three')]);
    check(next.toSet().containsAll({2, 3}), 'concurrent reservations collide');
    await service.server!.close(force: true);
    service = DeliveryServer(storage, admin, publicKeys, uploadToken: upload);
    await service.start(port: 0);
    origin = Uri.parse('http://127.0.0.1:${service.server!.port}');
    check(
      await reserve('one') == 1 && await reserve('four') == 4,
      'restart lost ledger',
    );

    final artifact = File('${dir.path}/patch.bytecode')
      ..writeAsBytesSync([1, 2, 3]);
    Future<Uint8List> manifest(String id, int number) async {
      final output = '${dir.path}/$id-$number.json';
      await sign(['sign', keys, artifact.path, output, baseline, id], number);
      return File(output).readAsBytesSync();
    }

    final first = await manifest('one', 1);
    final second = await manifest('two', 2);
    final verifier = SignedManifestVerifier(
      baselineId: baseline,
      releaseIdentity: releaseIdentity,
      publicKeys: publicKeys,
    );
    check(verifier.verify(first)?.patchNumber == 1, 'number not authenticated');
    final staged = await network.post(origin.resolve('/v1/uploads'),
        headers: {'authorization': 'Bearer $upload'},
        body: jsonEncode({'envelope': base64.encode(first),
          'artifact': base64.encode(artifact.readAsBytesSync())}));
    check(staged.statusCode == 201 && jsonDecode(staged.body)['patchNumber'] == 1,
        'numbered upload receipt');
    final activated = await network.post(origin.resolve('/v1/activate'),
        headers: {'authorization': 'Bearer $admin'},
        body: jsonEncode({'baselineId': baseline, 'patchId': 'one', 'kind': 'candidate'}));
    check(activated.statusCode == 201, 'numbered activation');
    final feed = await network.get(origin.resolve('/v1/check').replace(queryParameters: {'baselineId': baseline}));
    check(verifier.verify(feed.bodyBytes)?.patchNumber == 1, 'published number missing');
    final tampered = jsonDecode(utf8.decode(first)) as Map<String, dynamic>;
    tampered['manifest']['patchNumber'] = 99;
    check(
      verifier.verify(canonicalManifestBytes(tampered)) == null,
      'number tamper accepted',
    );
    final collision = await manifest('two', 1);
    check(
      (await network.post(
            origin.resolve('/v1/uploads'),
            headers: {'authorization': 'Bearer $upload'},
            body: jsonEncode({
              'envelope': base64.encode(collision),
              'artifact': base64.encode(artifact.readAsBytesSync()),
            }),
          )).statusCode ==
          409,
      'duplicate number accepted',
    );
    final clientRoot = Directory('${dir.path}/client');
    loader = SignedPatchLoader(root: clientRoot, verifier: verifier);
    check(
      loader.stageBytes(first, artifact.readAsBytesSync()) &&
          loader.currentPatchNumber == null,
      'download displayed',
    );
    var patch = await loader.load<void>((_) async {}, restoreBaseline: () {});
    check(
      patch?.patchNumber == 1 && loader.currentPatchNumber == null,
      'unhealthy load displayed',
    );
    check(
      loader.markHealthy(patch!) && loader.currentPatchNumber == 1,
      'healthy not displayed',
    );
    check(
      loader.stageBytes(second, artifact.readAsBytesSync()) &&
          loader.currentPatchNumber == 1,
      'pending changed current',
    );
    loader.close();
    loader = SignedPatchLoader(root: clientRoot, verifier: verifier);
    var attempts = 0;
    patch = await loader.load<void>((_) async {
      if (attempts++ == 0) throw StateError('candidate failed');
    }, restoreBaseline: () {});
    check(
      patch?.patchNumber == 1 &&
          loader.markHealthy(patch!) &&
          loader.currentPatchNumber == 1,
      'fallback number',
    );
    final withdrawn = jsonDecode(utf8.decode(first))['manifest'] as Map;
    withdrawn['revoked'] = true;
    final unsigned = File('${dir.path}/withdraw.json')
      ..writeAsStringSync(jsonEncode(withdrawn));
    final envelope = '${dir.path}/withdraw-signed.json';
    await sign(['sign-json', keys, unsigned.path, envelope]);
    check(
      loader.withdrawSigned(File(envelope).readAsBytesSync()),
      'withdraw failed',
    );
    check(
      loader.currentPatchNumber == 1,
      'running version changed before restart',
    );
    loader.close();
    loader = SignedPatchLoader(root: clientRoot, verifier: verifier);
    check(
      await loader.load<void>((_) async {}, restoreBaseline: () {}) == null &&
          loader.currentPatchNumber == null,
      'baseline not cleared',
    );
    check(await reserve('five') == 5, 'withdrawal reused number');
    print(
      'PASS: persistent unique reservations, signature binding, downloaded/pending/healthy/fallback/bundled display',
    );
  } finally {
    loader?.close();
    network.close();
    await service?.server?.close(force: true);
    dir.deleteSync(recursive: true);
  }
}
