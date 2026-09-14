import 'dart:io';
import 'project_cli.dart' as cli;

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

void main() {
  final project = Directory.systemTemp.createTempSync('project-cli-check.');
  try {
    Directory('${project.path}/lib').createSync();
    final pricing = File('${project.path}/lib/pricing.dart')
      ..writeAsStringSync('baseline');
    final other = File('${project.path}/lib/view.dart')
      ..writeAsStringSync('unchanged');
    const originalSpec = 'name: example\nflutter:\n  assets:\n    - assets/\n';
    final pubspec = File('${project.path}/pubspec.yaml')
      ..writeAsStringSync(originalSpec);
    Directory('${project.path}/assets').createSync();
    Directory('${project.path}/android').createSync();
    final asset = File('${project.path}/assets/example.txt')
      ..writeAsStringSync('original');
    final native = File('${project.path}/android/build.gradle')
      ..writeAsStringSync('original');
    final metadata = <String, dynamic>{
      'project': project.path,
      'patchLibrary': 'lib/pricing.dart',
      'sources': cli.sourceHashes(project),
    };
    cli.checkSources(metadata);
    pricing.writeAsStringSync('patched');
    cli.checkSources(metadata);
    void rejected(void Function() mutate, void Function() restore) {
      mutate();
      var denied = false;
      try {
        cli.checkSources(metadata);
      } on FormatException {
        denied = true;
      }
      require(denied, 'out-of-scope modification accepted');
      restore();
    }

    rejected(
      () => other.writeAsStringSync('changed'),
      () => other.writeAsStringSync('unchanged'),
    );
    rejected(
      () => pubspec.writeAsStringSync('new dependency'),
      () => pubspec.writeAsStringSync(originalSpec),
    );
    rejected(
      () => asset.writeAsStringSync('changed'),
      () => asset.writeAsStringSync('original'),
    );
    rejected(
      () => native.writeAsStringSync('changed'),
      () => native.writeAsStringSync('original'),
    );
    final added = File('${project.path}/lib/added.dart');
    rejected(
      () => added.writeAsStringSync('new library'),
      () => added.deleteSync(),
    );
    rejected(
      () => other.deleteSync(),
      () => other.writeAsStringSync('unchanged'),
    );
    cli.checkSources(metadata);
    print(
      'PASS: one-library patch scope; other sources, additions, deletions and dependency edits rejected',
    );
  } finally {
    project.deleteSync(recursive: true);
  }
}
