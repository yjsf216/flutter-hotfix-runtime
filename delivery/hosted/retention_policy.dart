import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../spikes/patch_ir_spike/tool/delivery_server.dart' show readBody;

/// Opt-in lifecycle for CI-owned baselines. Legacy uploads are never adopted.
/// One server process owns this directory; enabled POST routes must serialize.
class RetentionPolicy {
  RetentionPolicy(
    this.root,
    this.adminToken,
    this.uploadToken, {
    this.enabled = false,
    this.purgeArtifacts,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now {
    root.createSync(recursive: true);
    final file = File('${root.path}/retention.json');
    state = file.existsSync()
        ? Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map)
        : {
            'sequence': 0,
            'records': <String, dynamic>{},
            'leases': <String, dynamic>{},
          };
  }
  final Directory root;
  final String adminToken, uploadToken;
  final bool enabled;
  final DateTime Function() clock;
  final Future<void> Function(List<String>)? purgeArtifacts;
  late Map<String, dynamic> state;
  Map get records => state['records'] as Map;
  Map get leases => state['leases'] as Map;
  static final digest = RegExp(r'^[a-f0-9]{64}$');
  bool retired(String id) => records[id]?['retiredAt'] != null;
  bool inUse(String id) => leases.values.any(
    (v) =>
        v['baselineId'] == id &&
        DateTime.parse(v['expiresAt'] as String).isAfter(clock().toUtc()),
  );
  void save() {
    final temporary = File('${root.path}/retention.json.tmp');
    temporary.writeAsStringSync(jsonEncode(state), flush: true);
    temporary.renameSync('${root.path}/retention.json');
  }

  List<String> plan() {
    final groups = <String, List<Map>>{};
    for (final value in records.values) {
      final row = value as Map;
      if (retired(row['baselineId'] as String)) continue;
      final group = jsonEncode([row['appId'], row['platform'], row['abi'] ?? 'arm64', row['channel']]);
      groups.putIfAbsent(group, () => []).add(row);
    }
    return groups.values.expand((rows) {
      rows.sort((a, b) {
        final time = DateTime.parse(
          b['registeredAt'] as String,
        ).compareTo(DateTime.parse(a['registeredAt'] as String));
        return time != 0
            ? time
            : (b['sequence'] as int).compareTo(a['sequence'] as int);
      });
      return rows.skip(2).map((r) => r['baselineId'] as String);
    }).toList();
  }

  void reconcile() {
    leases.removeWhere(
      (_, value) => !DateTime.parse(
        value['expiresAt'] as String,
      ).isAfter(clock().toUtc()),
    );
    if (enabled) {
      for (final id in plan()) {
        if (inUse(id)) continue;
        records[id]['retiredAt'] = clock().toUtc().toIso8601String();
        records[id]['cleanupStatus'] = 'pending';
      }
    }
    save();
  }

  void register(String id, String channel) {
    if (!digest.hasMatch(id) ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(channel)) {
      throw const FormatException('retention identity');
    }
    final file = File('${root.path}/baselines/$id.json');
    if (!file.existsSync() ||
        File('${root.path}/baselines/$id.deleted').existsSync()) {
      throw const FormatException('completed visible baseline required');
    }
    final baseline = jsonDecode(file.readAsStringSync()) as Map;
    if (baseline['baselineId'] != id ||
        baseline['packageUrl'] is! String ||
        baseline['registeredAt'] is! String ||
        DateTime.tryParse(baseline['registeredAt'] as String) == null) {
      throw const FormatException('completed upload receipt required');
    }
    if (records.containsKey(id)) {
      if (records[id]['channel'] != channel || retired(id)) {
        throw const FormatException('immutable or retired baseline');
      }
    } else {
      final sequence = (state['sequence'] as int) + 1;
      state['sequence'] = sequence;
      records[id] = {
        'baselineId': id,
        'appId': baseline['appId'],
        'platform': baseline['platform'],
        'abi': baseline['abi'] ?? 'arm64',
        'release': baseline['release'],
        'channel': channel,
        'sequence': sequence,
        'registeredAt': baseline['registeredAt'],
      };
    }
    reconcile();
  }

  Map<String, dynamic> view() => {
    'enabled': enabled,
    'keep': 2,
    'plannedRetirements': plan(),
    'records': records.values
        .map(
          (v) => {
            ...Map<String, dynamic>.from(v as Map),
            'inUse': inUse(v['baselineId'] as String),
          },
        )
        .toList(),
  };

  /// Shared digest objects are retained while ANY live or legacy baseline uses them.
  Set<String> hashes({required bool old}) {
    final result = <String>{};
    final baselines = Directory('${root.path}/baselines');
    if (baselines.existsSync()) {
      for (final file
          in baselines.listSync(followLinks: false).whereType<File>()) {
        if (!RegExp(
          r'^[a-f0-9]{64}\.json$',
        ).hasMatch(file.uri.pathSegments.last))
          continue;
        final row = jsonDecode(file.readAsStringSync()) as Map;
        if (retired(row['baselineId'] as String) == old)
          result.add(row['packageSha256'] as String);
      }
    }
    for (final file in root.listSync(followLinks: false).whereType<File>()) {
      if (!RegExp(
        r'^[a-f0-9]{64}\.[A-Za-z0-9._-]+\.(candidate|json)$',
      ).hasMatch(file.uri.pathSegments.last))
        continue;
      final manifest =
          (jsonDecode(file.readAsStringSync()) as Map)['manifest'] as Map;
      if (retired(manifest['baselineId'] as String) == old)
        result.add(manifest['artifactSha256'] as String);
    }
    if (result.any((value) => !digest.hasMatch(value)))
      throw StateError('invalid stored artifact hash');
    return result;
  }

  bool blockedBlob(String hash) =>
      records.values.any((r) => r['retiredAt'] != null) &&
      hashes(old: true).contains(hash) &&
      !hashes(old: false).contains(hash);

  Future<void> cleanup() async {
    if (!enabled) throw StateError('retention disabled');
    if (purgeArtifacts == null)
      throw StateError('object deletion and CDN purge adapter not configured');
    final pending = records.keys
        .where(
          (id) =>
              retired(id as String) &&
              records[id]['cleanupStatus'] != 'complete',
        )
        .cast<String>()
        .toList();
    if (pending.isEmpty) return;
    final removable = hashes(old: true).difference(hashes(old: false)).toList()
      ..sort();
    // Retired metadata is retained for audit/reference accounting. Do not report
    // cleanup complete until BOTH origin removal and CDN purge are acknowledged.
    if (removable.isNotEmpty) await purgeArtifacts!(removable);
    for (final hash in removable) {
      final file = File('${root.path}/$hash.blob');
      if (file.existsSync()) file.deleteSync();
    }
    for (final id in pending) {
      records[id]['cleanupStatus'] = 'complete';
      records[id]['cleanedAt'] = clock().toUtc().toIso8601String();
    }
    save();
  }

  Future<bool> handle(HttpRequest request) async {
    if (!request.uri.path.startsWith('/v1/retention')) return false;
    final auth = request.headers.value('authorization');
    final admin = auth == 'Bearer $adminToken';
    if (!admin && auth != 'Bearer $uploadToken') {
      request.response.statusCode = 401;
      return true;
    }
    if (request.method == 'GET' && request.uri.path == '/v1/retention') {
      request.response.write(jsonEncode(view()));
      return true;
    }
    if (request.method != 'POST') {
      request.response.statusCode = 404;
      return true;
    }
    final body = jsonDecode(utf8.decode(await readBody(request, 4096)));
    if (body is! Map) throw const FormatException('retention body');
    switch (request.uri.path) {
      case '/v1/retention/register':
        if (body.length != 2 ||
            body['baselineId'] is! String ||
            body['channel'] is! String)
          throw const FormatException('registration');
        register(body['baselineId'] as String, body['channel'] as String);
        break;
      case '/v1/retention/lease':
        final id = body['baselineId'];
        final action = body['action'];
        if (id is! String ||
            !digest.hasMatch(id) ||
            !records.containsKey(id) ||
            !{'acquire', 'renew', 'release'}.contains(action) ||
            body.keys.any(
              (k) => !{'baselineId', 'action', 'token'}.contains(k),
            )) {
          throw const FormatException('lease');
        }
        if (retired(id)) {
          request.response.statusCode = 410;
          return true;
        }
        leases.removeWhere(
          (_, value) => !DateTime.parse(
            value['expiresAt'] as String,
          ).isAfter(clock().toUtc()),
        );
        if (action == 'acquire' &&
            (leases.length >= 256 || enabled && plan().contains(id))) {
          request.response.statusCode = 409;
          return true;
        }
        final token = action == 'acquire'
            ? List.generate(
                32,
                (_) => Random.secure()
                    .nextInt(256)
                    .toRadixString(16)
                    .padLeft(2, '0'),
              ).join()
            : body['token'];
        if (action != 'acquire' &&
            (token is! String ||
                leases[token]?['baselineId'] != id ||
                !DateTime.parse(
                  leases[token]['expiresAt'] as String,
                ).isAfter(clock().toUtc()))) {
          request.response.statusCode = 409;
          return true;
        }
        if (action == 'release') {
          leases.remove(token);
          reconcile();
        } else {
          leases[token] = {
            'baselineId': id,
            'expiresAt': clock()
                .toUtc()
                .add(const Duration(minutes: 15))
                .toIso8601String(),
          };
          save();
        }
        request.response.write(
          jsonEncode({
            'status': action,
            if (action != 'release') 'token': token,
          }),
        );
        return true;
      case '/v1/retention/reconcile':
        if (!admin) {
          request.response.statusCode = 403;
          return true;
        }
        if (body.isNotEmpty) throw const FormatException('empty body required');
        reconcile();
        break;
      case '/v1/retention/cleanup':
        if (!admin) {
          request.response.statusCode = 403;
          return true;
        }
        if (body.isNotEmpty) throw const FormatException('empty body required');
        if (!enabled || purgeArtifacts == null) {
          request.response.statusCode = 409;
          return true;
        }
        await cleanup();
        break;
      default:
        request.response.statusCode = 404;
        return true;
    }
    request.response.write(jsonEncode(view()));
    return true;
  }
}
