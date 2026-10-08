import 'dart:io';
import 'git_workflow.dart';

Future<void> main() async {
  final project = Directory.systemTemp.createTempSync('hotfix-git-check.');
  Future<void> commit() async {
    await git(project, ['add', '.']);
    await git(project, [
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.invalid',
      '-c',
      'commit.gpgsign=false',
      'commit',
      '-m',
      'fixture',
    ]);
  }

  Future<void> rejects(Future<Object?> Function() action) async {
    try {
      await action();
    } on FormatException {
      return;
    }
    throw StateError('Expected rejection');
  }

  try {
    await git(project, ['init']);
    Directory('${project.path}/lib').createSync();
    final source = File('${project.path}/lib/pricing.dart')
      ..writeAsStringSync('int price() => 1;\n');
    final other = File('${project.path}/lib/main.dart')
      ..writeAsStringSync('void main() {}\n');
    await commit();
    final baseline = await cleanGitHead(project);
    final metadata = {
      'project': project.path,
      'gitCommit': baseline,
      'patchLibrary': 'lib/pricing.dart',
    };
    await rejects(() => checkGitPatch(metadata, 'HEAD')); // no changes
    source.writeAsStringSync('int price() => 2;\n');
    await rejects(() => checkGitPatch(metadata, 'HEAD')); // dirty
    await commit();
    final target = await checkGitPatch(metadata, 'HEAD');
    if (target != await cleanGitHead(project)) throw StateError('Wrong target');
    await rejects(() => checkGitPatch(metadata, baseline)); // wrong checkout
    await rejects(() => checkGitPatch(metadata, '--help')); // ref is data
    await rejects(
      () => checkGitPatch({...metadata}..remove('gitCommit'), 'HEAD'),
    );
    other.writeAsStringSync('void main() { throw 1; }\n');
    await commit();
    await rejects(() => checkGitPatch(metadata, 'HEAD')); // multiple files
    await checkGitPatch({
      ...metadata,
      'patchLibraries': ['lib/pricing.dart', 'lib/main.dart'],
    }, 'HEAD');
    other.writeAsStringSync('void main() {}\n');
    source.deleteSync();
    await commit();
    await rejects(() => checkGitPatch(metadata, 'HEAD')); // deletion
    print(
      'PASS: Git patch selection, dirty/no-change/wrong-ref/missing-provenance/multi-file/deletion rejection',
    );
  } finally {
    project.deleteSync(recursive: true);
  }
}
