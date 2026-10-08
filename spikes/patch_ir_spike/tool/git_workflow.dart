import 'dart:io';

List<String> patchPaths(Map<String, dynamic> metadata) =>
    (metadata['patchLibraries'] as List? ?? [metadata['patchLibrary']])
        .cast<String>();

Future<String> git(Directory project, List<String> args) async {
  final result = await Process.run('git', ['-C', project.path, ...args]);
  if (result.exitCode != 0) {
    throw FormatException('Git command failed: ${args.first}');
  }
  return result.stdout as String;
}

/// Never switches branches, commits, resets, or stashes the user's checkout.
Future<String> cleanGitHead(Directory project) async {
  final root = (await git(project, ['rev-parse', '--show-toplevel'])).trim();
  if (Directory(root).resolveSymbolicLinksSync() !=
      project.resolveSymbolicLinksSync()) {
    throw const FormatException(
      'Git workflow requires the project at repository root',
    );
  }
  if ((await git(project, [
    'status',
    '--porcelain',
    '--untracked-files=all',
  ])).isNotEmpty) {
    throw const FormatException(
      'Commit or move pending files first; Git workflow requires a clean checkout',
    );
  }
  return (await git(project, ['rev-parse', '--verify', 'HEAD'])).trim();
}

Future<String> checkGitPatch(Map<String, dynamic> metadata, String ref) async {
  final base = metadata['gitCommit'];
  if (base is! String || !RegExp(r'^[a-f0-9]{40,64}$').hasMatch(base)) {
    throw const FormatException(
      'Baseline has no Git provenance; build a new release-git baseline',
    );
  }
  final project = Directory(metadata['project'] as String);
  final head = await cleanGitHead(project);
  final target = (await git(project, [
    'rev-parse',
    '--verify',
    '--end-of-options',
    '$ref^{commit}',
  ])).trim();
  if (target != head) {
    throw const FormatException(
      'Check out the requested source commit before patch-git',
    );
  }
  final paths = (await git(project, [
    'diff',
    '--no-renames',
    '--name-only',
    '-z',
    base,
    target,
    '--',
  ])).split('\u0000').where((p) => p.isNotEmpty).toList();
  if (paths.isEmpty)
    throw const FormatException('No changes relative to baseline');
  final unsupported = paths
      .where((p) => !patchPaths(metadata).contains(p))
      .toList();
  if (unsupported.isNotEmpty) {
    throw FormatException(
      'New base app required; unsupported changed files: ${unsupported.join(', ')}',
    );
  }
  for (final path in paths) {
    final source = File('${project.path}/$path');
    if (FileSystemEntity.typeSync(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException(
        'Patch library must remain a regular file (no deletion or symlink)',
      );
    }
  }
  return target;
}
