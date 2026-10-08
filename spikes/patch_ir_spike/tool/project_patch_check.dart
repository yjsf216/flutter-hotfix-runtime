import 'dart:io';
import 'project_cli.dart' as cli;

/// Local device verification only; use patch-git for commit-pinned releases.
Future<void> main(List<String> args) async {
  if (args.length != 2) throw ArgumentError('BASELINE OUTPUT');
  final metadata = cli.json(cli.file('${args[0]}/project.json'));
  final project = Directory(metadata['project'] as String);
  final before = cli.sourceHashes(project);
  final pending = cli.file('${args[1]}.git-pending');
  if (pending.existsSync() || Directory(args[1]).existsSync())
    throw StateError('Use fresh output');
  pending.parent.createSync(recursive: true);
  pending.writeAsStringSync(
    'Local worktree validation incomplete\n',
    flush: true,
  );
  await cli.command([
    'patch',
    args[0],
    '${project.path}/${metadata['patchLibrary']}',
    args[1],
  ], projectPatch: true);
  final after = cli.sourceHashes(project);
  if (before.length != after.length ||
      before.entries.any((e) => after[e.key] != e.value)) {
    throw StateError('Worktree changed during compilation; discard output');
  }
  pending.deleteSync();
  cli.write(cli.file('${args[1]}/worktree-changes.json'), {
    'changedFiles': before.entries
        .where(
          (entry) => (metadata['sources'] as Map)[entry.key] != entry.value,
        )
        .map((entry) => entry.key)
        .toList(),
  });
  print('PASS: local worktree patch; no Git release provenance claimed');
}
