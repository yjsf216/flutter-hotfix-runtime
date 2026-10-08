import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../signed_manifest.dart';
import 'signature_check.dart' show manifestLifetime;

Future<void> main(List<String> args) async {
  if (args.length == 6 && args[0] == 'policy') {
    final baseline = Directory(args[1]);
    final patch = Directory(args[2]);
    final keys = Directory(args[3]);
    final output = Directory(args[4]);
    final percent = int.tryParse(args[5]);
    if (output.existsSync() ||
        args[5] != 'withdraw' &&
            (percent == null || percent < 0 || percent > 100)) {
      throw ArgumentError('fresh OUTPUT and 0..100 or withdraw required');
    }
    final recipe =
        jsonDecode(
              File('${baseline.path}/release/release.json').readAsStringSync(),
            )
            as Map;
    final original =
        jsonDecode(File('${patch.path}/manifest.json').readAsStringSync())
            as Map;
    final manifest = Map<String, dynamic>.from(original['manifest'] as Map);
    final key = File('${keys.path}/public-key.txt').readAsStringSync().trim();
    final defines = recipe['buildRecipe']['environmentDefines'] as Map;
    if (key != defines['HOTFIX_TEST_PUBLIC_KEY'])
      throw StateError('signing key mismatch');
    final identity = Map<String, Object?>.from(manifest['identity'] as Map);
    if (identity['appId'] != defines['HOTFIX_APP_ID'] ||
        identity['release'] != defines['HOTFIX_RELEASE'] ||
        identity['platform'] != defines['HOTFIX_PLATFORM'])
      throw StateError('identity mismatch');
    final verifier = SignedManifestVerifier(
      baselineId: recipe['baselineId'] as String,
      releaseIdentity: identity,
      publicKeys: {'spike-p256-1': base64.decode(key)},
    );
    final verified = verifier.verify(
      File('${patch.path}/manifest.json').readAsBytesSync(),
      allowExpiredHealthy: true,
      allowRevocation: true,
    );
    final bytes = File('${patch.path}/patch.bytecode').readAsBytesSync();
    if (verified == null ||
        !verified.matchesArtifact(bytes) ||
        verified.revoked && args[5] != 'withdraw') {
      throw StateError('invalid source patch or attempt to undo revocation');
    }
    var now = DateTime.now().toUtc();
    final previous = DateTime.parse(manifest['issuedAt'] as String);
    if (now.difference(previous).inSeconds < 1) {
      await Future<void>.delayed(const Duration(seconds: 1));
      now = DateTime.now().toUtc();
    }
    String stamp(DateTime time) =>
        '${time.toIso8601String().split('.').first}Z';
    manifest['issuedAt'] = stamp(now);
    manifest['expiresAt'] = stamp(now.add(manifestLifetime()));
    manifest['rolloutPercent'] = percent ?? 0;
    manifest['revoked'] = args[5] == 'withdraw';
    output.createSync(recursive: true);
    File('${output.path}/patch.bytecode').writeAsBytesSync(bytes, flush: true);
    final unsigned = File('${output.path}/policy.json')
      ..writeAsStringSync(jsonEncode(manifest));
    final signer = File.fromUri(
      Platform.script,
    ).parent.uri.resolve('signature_check.dart').toFilePath();
    final result = await Process.run(Platform.resolvedExecutable, [
      signer,
      'sign-json',
      keys.path,
      unsigned.path,
      '${output.path}/manifest.json',
    ]);
    if (result.exitCode != 0 ||
        verifier.verify(
              File('${output.path}/manifest.json').readAsBytesSync(),
              allowRevocation: true,
            ) ==
            null)
      throw StateError('policy signature failed');
    print('PASS: signed policy ready for explicit publication');
    return;
  }
  if (!(args.length == 4 && args[0] == 'pause' ||
      args.length == 2 && args[0] == 'stats')) {
    throw ArgumentError(
      'policy BASELINE PATCH KEY_DIR OUTPUT PERCENT|withdraw; pause ORIGIN BASELINE true|false; stats ORIGIN',
    );
  }
  final origin = Uri.parse(args[1]);
  if (origin.host.isEmpty ||
      origin.userInfo.isNotEmpty ||
      origin.hasQuery ||
      origin.hasFragment ||
      origin.path != '' && origin.path != '/' ||
      origin.scheme != 'https' &&
          !(origin.scheme == 'http' &&
              Platform.environment['HOTFIX_ALLOW_DEV_HTTP'] == 'true')) {
    throw ArgumentError('HTTPS origin required');
  }
  final token = Platform.environment['HOTFIX_PUBLISH_TOKEN'] ?? '';
  if (token.length < 24) throw ArgumentError('publish token required');
  final client = http.Client();
  try {
    final pause = args[0] == 'pause';
    if (pause &&
        (args[3] != 'true' && args[3] != 'false' ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(args[2]))) {
      throw ArgumentError('invalid baseline or paused value');
    }
    final request =
        http.Request(
            pause ? 'POST' : 'GET',
            origin.resolve(pause ? '/v1/pause' : '/v1/stats'),
          )
          ..followRedirects = false
          ..headers['authorization'] = 'Bearer $token';
    if (pause)
      request.body = jsonEncode({
        'baselineId': args[2],
        'paused': args[3] == 'true',
      });
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != (pause ? 204 : 200))
      throw StateError('control request failed: ${response.statusCode}');
    if (pause) {
      print(
        'PASS: distribution paused=${args[3]}; installed patches unchanged',
      );
    } else {
      final bytes = BytesBuilder(copy: false);
      await (() async {
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 1024 * 1024)
            throw StateError('statistics exceed limit');
          bytes.add(chunk);
        }
      })().timeout(const Duration(seconds: 15));
      print(utf8.decode(bytes.takeBytes()));
    }
  } finally {
    client.close();
  }
}
