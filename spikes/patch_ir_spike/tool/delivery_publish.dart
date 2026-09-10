import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Private signing keys stay on the build machine; only signed bytes are sent.
Future<void> main(List<String> args) async {
  if (args.length != 3)
    throw ArgumentError('delivery_publish.dart ORIGIN MANIFEST BYTECODE');
  final origin = Uri.parse(args[0]);
  if (origin.userInfo.isNotEmpty ||
      origin.host.isEmpty ||
      origin.hasQuery ||
      origin.hasFragment ||
      origin.path != '' && origin.path != '/' ||
      origin.scheme != 'https' &&
          !(origin.scheme == 'http' &&
              Platform.environment['HOTFIX_ALLOW_DEV_HTTP'] == 'true')) {
    throw ArgumentError(
      'HTTPS origin required (explicit dev HTTP opt-in available)',
    );
  }
  final token = Platform.environment['HOTFIX_PUBLISH_TOKEN'] ?? '';
  if (token.length < 24) throw ArgumentError('HOTFIX_PUBLISH_TOKEN required');
  final envelope = File(args[1]);
  final artifact = File(args[2]);
  if (envelope.lengthSync() > 16384 ||
      artifact.lengthSync() > 8 * 1024 * 1024) {
    throw ArgumentError('MVP limit: 16 KiB envelope, 8 MiB bytecode');
  }
  final client = http.Client();
  try {
    final request = http.Request('POST', origin.resolve('/v1/releases'))
      ..followRedirects = false
      ..headers.addAll({
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      })
      ..body = jsonEncode({
        'envelope': base64.encode(envelope.readAsBytesSync()),
        'artifact': base64.encode(artifact.readAsBytesSync()),
      });
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 201)
      throw StateError('publish failed: HTTP ${response.statusCode}');
    print('Published signed patch for next-start delivery');
  } finally {
    client.close();
  }
}
