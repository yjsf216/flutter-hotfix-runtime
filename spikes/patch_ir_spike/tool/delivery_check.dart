import 'dart:convert';
import 'dart:io';

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
    loader.close();
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
