import 'dart:io';
import 'dart:convert';
import 'dart:async';
import '../../spikes/patch_ir_spike/tool/delivery_server.dart' as delivery;
import '../../spikes/patch_ir_spike/tool/oss_artifact_store.dart';
import 'baseline_registry.dart';
import 'retention_policy.dart';
import 'artifact_retirement.dart';

Future<void> main(List<String> args) async {
  for (final key in const [
    'HOTFIX_PUBLISH_TOKEN',
    'HOTFIX_UPLOAD_TOKEN',
    'HOTFIX_OSSUTIL',
    'HOTFIX_OSS_CONFIG',
    'HOTFIX_OSS_BUCKET',
    'HOTFIX_OSS_PREFIX',
    'HOTFIX_CDN_BLOB_BASE',
  ]) {
    if ((Platform.environment[key] ?? '').isEmpty) {
      stderr.writeln('Missing required server configuration: $key');
      exitCode = 2;
      return;
    }
  }
  if (args.length != 2)
    throw ArgumentError('server.dart STORAGE PUBLIC_KEY_FILE');
  final env = Platform.environment;
  final retentionEnabled = env['HOTFIX_RETENTION_ENABLED'] == 'true';
  final retireExecutable = env['HOTFIX_RETIRE_EXECUTABLE'];
  if (retentionEnabled &&
      (retireExecutable == null ||
          !retireExecutable.startsWith('/') ||
          !File(retireExecutable).existsSync())) {
    throw StateError(
      'Retention requires an explicit object deletion/CDN purge adapter',
    );
  }
  final retention = RetentionPolicy(
    Directory(args[0]),
    env['HOTFIX_PUBLISH_TOKEN']!,
    env['HOTFIX_UPLOAD_TOKEN']!,
    enabled: retentionEnabled,
    purgeArtifacts: retireExecutable == null
        ? null
        : (hashes) => purgeArtifacts(retireExecutable, hashes),
  );
  final mutations = SerialMutations();
  final store = OssArtifactStore(
    env['HOTFIX_OSSUTIL']!,
    env['HOTFIX_OSS_CONFIG']!,
    env['HOTFIX_OSS_BUCKET']!,
    env['HOTFIX_OSS_PREFIX']!,
    Uri.parse(env['HOTFIX_CDN_BLOB_BASE']!),
  );
  final registry = BaselineRegistry(
    Directory('${args[0]}/baselines'),
    env['HOTFIX_PUBLISH_TOKEN']!,
    env['HOTFIX_UPLOAD_TOKEN']!,
    store.storeFile,
    isRetired: retention.retired,
  );
  final service = delivery.DeliveryServer(
    Directory(args[0]),
    env['HOTFIX_PUBLISH_TOKEN']!,
    {'spike-p256-1': base64.decode(File(args[1]).readAsStringSync().trim())},
    uploadToken: env['HOTFIX_UPLOAD_TOKEN'],
    storeArtifact: store.store,
    extraRoute: (request) async =>
        await retention.handle(request) || await registry.handle(request),
    isRetired: retention.retired,
    isBlobRetired: retention.blockedBlob,
    mutationGate: retentionEnabled ? mutations.run : null,
  );
  await service.start(
    host: env['HOTFIX_BIND'] ?? '127.0.0.1',
    port: int.parse(env['HOTFIX_PORT'] ?? '8080'),
  );
  if (retentionEnabled) {
    var running = false;
    Timer.periodic(const Duration(minutes: 1), (_) async {
      if (running) return;
      running = true;
      try {
        await mutations.run(() async {
          retention.reconcile();
          await retention.cleanup();
        });
      } catch (_) {
        stderr.writeln(
          'Retention cleanup pending; origin/CDN completion not confirmed',
        );
      } finally {
        running = false;
      }
    });
  }
  print(
    'Hosted delivery service listening on ${service.server!.address.address}:${service.server!.port}',
  );
}
