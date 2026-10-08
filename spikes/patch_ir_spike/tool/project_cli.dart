import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';
import 'compile_dbc3_patch.dart' as compiler;
import 'git_workflow.dart';

final repo = File.fromUri(Platform.script).parent.parent.parent.parent;
String hash(File f) => sha256.convert(f.readAsBytesSync()).toString();
Never fail(String message) => throw FormatException(message);
String env(String name) =>
    Platform.environment[name] ?? (throw ArgumentError('$name required'));
File file(String path) => File(path).absolute;
Map<String, String> appDefines(Map<String, dynamic> config) {
  final values = Map<String, String>.from(config['dartDefines'] as Map? ?? {});
  for (final key in values.keys) {
    if (key.isEmpty ||
        key.startsWith('dart.') ||
        key.startsWith('flutter.') ||
        key.startsWith('HOTFIX_')) {
      fail('dartDefines contains a reserved compiler/runtime key');
    }
  }
  return values;
}

Future<void> run(String executable, List<String> args) async {
  final p = await Process.start(
    executable,
    args,
    mode: ProcessStartMode.inheritStdio,
  );
  if (await p.exitCode != 0)
    fail('command failed: ${File(executable).uri.pathSegments.last}');
}

Map<String, dynamic> json(File f) =>
    jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
void write(File f, Object value) => f.writeAsStringSync(
  const JsonEncoder.withIndent('  ').convert(value),
  flush: true,
);

Map<String, String> sourceHashes(Directory project) {
  final result = <String, String>{};
  void add(String relative) {
    if (relative.startsWith('/') ||
        relative.split('/').contains('..') ||
        relative.contains('\\'))
      fail('input must stay inside project');
    final path = '${project.path}/$relative';
    final kind = FileSystemEntity.typeSync(path, followLinks: false);
    if (kind == FileSystemEntityType.link)
      fail('source symlinks are unsupported');
    if (kind == FileSystemEntityType.file) result[relative] = hash(File(path));
    if (kind == FileSystemEntityType.directory) {
      for (final child in Directory(path).listSync(followLinks: false)) {
        final name = child.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final nativeInput =
            relative == 'android' ||
            relative.startsWith('android/') ||
            relative == 'ios' ||
            relative.startsWith('ios/');
        if (nativeInput &&
            {
              'build',
              'Pods',
              '.gradle',
              '.kotlin',
              '.cxx',
              '.symlinks',
              'ephemeral',
              '.DS_Store',
            }.contains(name))
          continue;
        add('$relative/$name');
      }
    }
  }

  for (final directory in ['lib', 'android', 'ios']) {
    add(directory);
  }
  final spec = loadYaml(
    File('${project.path}/pubspec.yaml').readAsStringSync(),
  );
  if (spec is! Map) fail('invalid pubspec.yaml');
  final flutter = spec['flutter'] as Map?;
  for (final asset in flutter?['assets'] as List? ?? []) {
    add((asset is String ? asset : (asset as Map)['path']) as String);
  }
  for (final font in flutter?['fonts'] as List? ?? []) {
    for (final asset in (font as Map)['fonts'] as List) {
      add((asset as Map)['asset'] as String);
    }
  }
  for (final name in [
    'pubspec.yaml',
    'pubspec.lock',
    '.dart_tool/package_config.json',
    '.dart_tool/flutter_build/dart_plugin_registrant.dart',
  ]) {
    final f = File('${project.path}/$name');
    if (f.existsSync()) result[name] = hash(f);
  }
  return result;
}

void checkSources(Map<String, dynamic> metadata) {
  final before = Map<String, String>.from(metadata['sources'] as Map);
  final current = sourceHashes(Directory(metadata['project'] as String));
  for (final path in patchPaths(metadata)) {
    if (!before.containsKey(path) || !current.containsKey(path))
      fail('Patch source added or deleted: $path');
    before.remove(path);
    current.remove(path);
  }
  if (before.length != current.length ||
      before.entries.any((e) => current[e.key] != e.value)) {
    fail(
      'non-patchable source or dependencies changed; publish a new base app',
    );
  }
}

Future<void> main(List<String> args) async {
  try {
    await command(args);
  } on Object catch (e) {
    stderr.writeln('ERROR: $e');
    exitCode = 1;
  }
}

Future<void> command(List<String> args, {bool projectPatch = false}) async {
  if (args.isEmpty || args.first == '--help') {
    print(
      'hotfix release CONFIG OUTPUT\nhotfix patch BASELINE UPDATED_LIBRARY OUTPUT\n'
      'hotfix release-git CONFIG OUTPUT\nhotfix patch-git BASELINE REF OUTPUT\n'
      'hotfix sign BASELINE PATCH_DIR KEY_DIR PATCH_ID\nhotfix publish ORIGIN MANIFEST BYTECODE\n'
      'hotfix serve STORAGE PUBLIC_KEY_FILE\nToolchains: DART_BIN, DART_SDK_SOURCE, FLUTTER_SDK, GEN_SNAPSHOT',
    );
    print(
      'hotfix policy BASELINE PATCH_DIR KEY_DIR OUTPUT PERCENT|withdraw\n'
      'hotfix pause ORIGIN BASELINE_ID true|false\nhotfix stats ORIGIN',
    );
    return;
  }
  final action = args.first;
  if ({'policy', 'pause', 'stats'}.contains(action)) {
    await run(Platform.resolvedExecutable, [
      '${repo.path}/spikes/patch_ir_spike/tool/delivery_control.dart',
      ...args,
    ]);
    return;
  }
  if (action == 'release-git' && args.length == 3) {
    final configFile = file(args[1]);
    final config = json(configFile);
    final project = Directory.fromUri(
      configFile.parent.uri.resolve(config['project'] as String),
    );
    final commit = await cleanGitHead(project);
    await command(['release', ...args.skip(1)]);
    if (await cleanGitHead(project) != commit)
      fail('Git checkout changed during build');
    final metadataFile = file('${args[2]}/project.json');
    write(metadataFile, {...json(metadataFile), 'gitCommit': commit});
    print('PASS: Git baseline $commit');
    return;
  }
  if (action == 'patch-git' && args.length == 4) {
    final metadata = json(file('${args[1]}/project.json'));
    final commit = await checkGitPatch(metadata, args[2]);
    checkSources(metadata);
    final project = Directory(metadata['project'] as String);
    final before = sourceHashes(project);
    final pending = file('${args[3]}.git-pending');
    if (pending.existsSync() || Directory(args[3]).existsSync())
      fail('Use a fresh patch output');
    pending.parent.createSync(recursive: true);
    pending.writeAsStringSync('Git patch validation incomplete\n', flush: true);
    await command([
      'patch',
      args[1],
      '${project.path}/${metadata['patchLibrary']}',
      args[3],
    ], projectPatch: true);
    final after = sourceHashes(project);
    if (await cleanGitHead(project) != commit ||
        before.length != after.length ||
        before.entries.any((e) => after[e.key] != e.value)) {
      fail('Sources changed during compilation; discard this patch output');
    }
    write(file('${args[3]}/git-provenance.json'), {
      'baselineCommit': metadata['gitCommit'],
      'sourceCommit': commit,
      'patchLibrary': metadata['patchLibrary'],
      'patchableFiles': patchPaths(metadata),
      'changedFiles': (await git(project, [
        'diff',
        '--no-renames',
        '--name-only',
        '-z',
        metadata['gitCommit'] as String,
        commit,
        '--',
      ])).split('\u0000').where((path) => path.isNotEmpty).toList(),
    });
    pending.deleteSync();
    return;
  }
  if (action == 'publish' && args.length == 4 ||
      action == 'serve' && args.length == 3) {
    await run(Platform.resolvedExecutable, [
      '${repo.path}/spikes/patch_ir_spike/tool/${action == 'publish' ? 'delivery_publish' : 'delivery_server'}.dart',
      ...args.skip(1),
    ]);
    return;
  }
  if (action == 'sign' && args.length == 5) {
    if (file('${args[2]}.git-pending').existsSync())
      fail('Git patch validation incomplete; generate a fresh patch');
    final base = Directory(args[1]).absolute;
    final metadata = json(File('${base.path}/project.json'));
    final recipe = json(File('${base.path}/release/release.json'));
    final defines = recipe['buildRecipe']['environmentDefines'] as Map;
    final patch = Directory(args[2]).absolute;
    final manifest = File('${patch.path}/manifest.json');
    if (manifest.existsSync())
      fail(
        'manifest exists; publish it unchanged or use a fresh patch directory',
      );
    final patchMetadata = json(File('${patch.path}/metadata.json'));
    if (patchMetadata['baselineId'] != recipe['baselineId'])
      fail('patch baseline mismatch');
    if (File('${args[3]}/public-key.txt').readAsStringSync().trim() !=
        defines['HOTFIX_TEST_PUBLIC_KEY']) {
      fail('signing key does not match the embedded baseline trust anchor');
    }
    await run(Platform.resolvedExecutable, [
      '-DHOTFIX_APP_ID=${defines['HOTFIX_APP_ID']}',
      '-DHOTFIX_PLATFORM=${metadata['platform']}',
      '-DHOTFIX_RELEASE=${metadata['release']}',
      '${repo.path}/spikes/patch_ir_spike/tool/signature_check.dart',
      'sign',
      args[3],
      '${patch.path}/patch.bytecode',
      manifest.path,
      recipe['baselineId'] as String,
      args[4],
    ]);
    await run(Platform.resolvedExecutable, [
      '${repo.path}/spikes/patch_ir_spike/tool/verify_project_signature.dart',
      base.path,
      patch.path,
    ]);
    return;
  }
  if (!(action == 'release' && args.length == 3 ||
      action == 'patch' && args.length == 4)) {
    fail('unknown command/arguments; use --help');
  }
  final sdk = Directory(env('DART_SDK_SOURCE')).absolute;
  final flutter = Directory(env('FLUTTER_SDK')).absolute;
  final generator = file(env('GEN_SNAPSHOT'));
  final revision = await Process.run('git', [
    '-C',
    sdk.path,
    'rev-parse',
    'HEAD',
  ]);
  if (revision.exitCode != 0 ||
      '${revision.stdout}'.trim() != 'c70f78e7d682c158c15ca0c26c729b3ccb932284')
    fail('requires pinned Dart source revision');
  final platform = File(
    '${flutter.path}/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
  );
  if (!generator.existsSync() || !platform.existsSync())
    fail('target toolchain missing');
  if (File(
        '${flutter.path}/bin/internal/engine.version',
      ).readAsStringSync().trim() !=
      '42d3d75a56efe1a2e9902f52dc8006099c45d937')
    fail('requires pinned Flutter 3.41.9 Engine');
  if (action == 'release') {
    final configFile = file(args[1]);
    final config = json(configFile);
    final project = Directory(
      Directory.fromUri(
        configFile.parent.uri.resolve(config['project'] as String),
      ).resolveSymbolicLinksSync(),
    );
    final entry = config['entry'] as String;
    final allLibraries =
        config['patchScope'] == 'lib' || config['patchLibrary'] == null;
    if (config['patchScope'] != null && config['patchScope'] != 'lib')
      fail('Only patchScope lib is supported');
    final library = config['patchLibrary'] as String? ?? entry;
    for (final path in [entry, library]) {
      if (!path.startsWith('lib/') ||
          path.contains('..') ||
          path.contains('\\'))
        fail('entry/library must be under project lib/');
    }
    if (!['android', 'ios'].contains(config['platform']))
      fail('only Android/iOS arm64 are supported');
    final gn = File('${generator.parent.parent.path}/args.gn');
    if (!gn.existsSync() ||
        !gn.readAsStringSync().contains(
          'target_os = "${config['platform']}"',
        ) ||
        !gn.readAsStringSync().contains('dart_dynamic_modules = true') ||
        !gn.readAsStringSync().contains('target_cpu = "arm64"')) {
      fail(
        'GEN_SNAPSHOT must come from the matching pinned arm64 DDM Engine build',
      );
    }
    final output = Directory(args[2]).absolute;
    if (output.existsSync())
      fail('output already exists; baseline archives are immutable');
    final publicKey = File(
      env('HOTFIX_PUBLIC_KEY_FILE'),
    ).readAsStringSync().trim();
    final sources = sourceHashes(project);
    final packages = File('${project.path}/.dart_tool/package_config.json');
    output.createSync(recursive: true);
    final release = Directory('${output.path}/release');
    final registrant = File(
      '${project.path}/.dart_tool/flutter_build/dart_plugin_registrant.dart',
    );
    final registrationSources = registrant.existsSync()
        ? [
            registrant.uri,
            Uri.parse('package:flutter/src/dart_plugin_registrant.dart'),
          ]
        : <Uri>[];
    await compiler.compileBaseline(
      sdk: sdk,
      baselineUri: project.uri.resolve(library),
      entryUri: project.uri.resolve(entry),
      output: release,
      targetName: 'flutter',
      platformDillUri: platform.uri,
      packagesFileUri: packages.uri,
      genSnapshotUri: generator.uri,
      additionalSources: registrationSources,
      patchRoot: allLibraries ? project.uri.resolve('lib/') : null,
      retainedLibraries: {
        ...registrationSources,
        Uri.parse('dart:ui'),
        Uri.parse('package:flutter/src/widgets/framework.dart'),
      },
      environmentDefines: {
        ...appDefines(config),
        if (registrant.existsSync())
          'flutter.dart_plugin_registrant': registrant.uri.toString(),
        'HOTFIX_APP_ID': config['appId'] as String,
        'HOTFIX_PLATFORM': config['platform'] as String,
        'HOTFIX_RELEASE': config['release'] as String,
        'HOTFIX_TEST_PUBLIC_KEY': publicKey,
        'HOTFIX_NATIVE_STORE': 'true',
        'HOTFIX_UPDATE_ORIGIN': config['updateOrigin'] as String? ?? '',
        'HOTFIX_ALLOW_DEV_HTTP': '${config['allowDevelopmentHttp'] == true}',
      },
    );
    final ios = config['platform'] == 'ios';
    if (allLibraries) {
      final check = Directory('${output.path}/.unchanged-check');
      var unchanged = false;
      try {
        try {
          await compiler.compilePatch(
            sdk: sdk,
            release: release,
            updatedUri: project.uri.resolve(library),
            output: check,
            platformDillUri: platform.uri,
            packagesFileUri: packages.uri,
            genSnapshotUri: generator.uri,
          );
        } on FormatException catch (error) {
          if (error.message != 'no changed functions') rethrow;
          unchanged = true;
        }
        if (!unchanged || File('${check.path}/patch.bytecode').existsSync())
          fail('Unchanged baseline unexpectedly produced a patch');
        print('PASS: unchanged multi-library baseline comparison');
      } finally {
        if (check.existsSync()) check.deleteSync(recursive: true);
      }
    }
    await run(generator.path, [
      '--snapshot-kind=${ios ? 'app-aot-assembly' : 'app-aot-elf'}',
      '--${ios ? 'assembly' : 'elf'}=${output.path}/${ios ? 'snapshot.S' : 'libapp.so'}',
      '${release.path}/baseline.aot.dill',
    ]);
    final after = sourceHashes(project);
    if (sources.length != after.length ||
        sources.entries.any((e) => after[e.key] != e.value)) {
      fail(
        'project inputs changed during baseline compilation; use a fresh output',
      );
    }
    write(File('${output.path}/project.json'), {
      ...config,
      'patchLibrary': library,
      if (allLibraries)
        'patchLibraries':
            ((json(File('${release.path}/release.json'))['buildRecipe']
                        as Map)['patchSourceUris']
                    as List)
                .cast<String>()
                .map(Uri.parse)
                .map(
                  (uri) => uri.toFilePath().substring(project.path.length + 1),
                )
                .where(
                  (path) => path.endsWith('.dart') && sources.containsKey(path),
                )
                .toList()
              ..sort(),
      'project': project.path,
      'sources': sources,
      'generatorSha256': hash(generator),
      'schemaVersion': 1,
    });
    print(
      'PASS: frozen ${config['platform']} baseline; native packaging/signing remains separate',
    );
  } else {
    final base = Directory(args[1]).absolute;
    final metadata = json(File('${base.path}/project.json'));
    if (metadata['schemaVersion'] != 1 ||
        metadata['generatorSha256'] != hash(generator))
      fail('baseline/toolchain mismatch');
    if (metadata['patchLibraries'] != null && !projectPatch) {
      fail(
        'Multi-library baseline requires patch-git; external single-file candidates are not accepted',
      );
    }
    final project = Directory(metadata['project'] as String);
    checkSources(metadata);
    final output = Directory(args[3]).absolute;
    if (output.existsSync()) fail('patch output exists; use a fresh directory');
    await compiler.compilePatch(
      sdk: sdk,
      release: Directory('${base.path}/release'),
      updatedUri: file(args[2]).uri,
      output: output,
      platformDillUri: platform.uri,
      packagesFileUri: File(
        '${project.path}/.dart_tool/package_config.json',
      ).uri,
      genSnapshotUri: generator.uri,
    );
    print('PASS: patch generated without rebuilding the baseline');
  }
}
