import 'dart:convert';
import 'dart:io';

/// Managed builds reserve a durable number before signing. Never fall back to
/// a machine-local counter when the shared service is unavailable.
Future<int> reservePatchNumber(
  String origin,
  String baselineId,
  String patchId,
) async {
  final base = Uri.parse(origin);
  if (base.scheme != 'https' ||
      base.host.isEmpty ||
      base.userInfo.isNotEmpty ||
      base.hasQuery ||
      base.hasFragment ||
      !RegExp(r'^(?:/[A-Za-z0-9_-]+)*/?$').hasMatch(base.path)) {
    throw ArgumentError('HTTPS numbering API base required');
  }
  final token = Platform.environment['HOTFIX_UPLOAD_TOKEN'] ?? '';
  if (token.length < 24 || token.contains(RegExp(r'[\r\n]'))) {
    throw StateError(
      'HOTFIX_UPLOAD_TOKEN required for automatic patch numbering',
    );
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    return await (() async {
      final url = base.replace(
        path: base.path.replaceFirst(RegExp(r'/$'), '') + '/v1/patch-numbers',
      );
      final request = await client.postUrl(url);
      request.followRedirects = false;
      request.headers.set('authorization', 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'baselineId': baselineId, 'patchId': patchId}));
      final response = await request.close();
      if (response.statusCode != 200)
        throw StateError(
          'Number reservation rejected: HTTP ${response.statusCode}',
        );
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 4096)
          throw StateError('Oversized reservation receipt');
        bytes.addAll(chunk);
      }
      final receipt = jsonDecode(utf8.decode(bytes));
      if (receipt is! Map ||
          receipt['baselineId'] != baselineId ||
          receipt['patchId'] != patchId ||
          receipt['patchNumber'] is! int ||
          receipt['patchNumber'] < 1 ||
          receipt['patchNumber'] > 1000000) {
        throw StateError('Number reservation receipt mismatch');
      }
      return receipt['patchNumber'] as int;
    })().timeout(const Duration(seconds: 30));
  } finally {
    client.close(force: true);
  }
}
