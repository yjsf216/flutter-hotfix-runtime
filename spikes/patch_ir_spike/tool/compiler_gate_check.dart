import 'dart:io';

/// Real CFE inputs exercise compiler rejection, not just handcrafted Kernel.
Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Dart SDK source path required');
  final sdk = Directory(args.single).absolute;
  final spike = File.fromUri(Platform.script).parent.parent;
  final root = Directory.systemTemp.createTempSync('hotfix-compiler-gates-');
  try {
    final cases = [
      (
        'generic-class-layout',
        'class A<T> { T value; A(this.value); T f() => value; }',
        'class A<T> { T value; int extra = 0; A(this.value); T f() => value; }',
        'incompatible Kernel library',
      ),
      (
        'generator-to-eager',
        'class A { Iterable<int> f() sync* { yield 1; } }',
        'class A { Iterable<int> f() => [2]; }',
        'incompatible Kernel library',
      ),
      (
        'eager-to-generator',
        'class A { Iterable<int> f() => [1]; }',
        'class A { Iterable<int> f() sync* { yield 2; } }',
        'incompatible Kernel library',
      ),
      (
        'private-dynamic',
        'class A { int _x = 0; int f(dynamic v) => 0; }',
        'class A { int _x = 0; int f(dynamic v) => v._x; }',
        'dynamic getter',
      ),
      (
        'private-symbol',
        'class A { Symbol f() => #public; }',
        'class A { Symbol f() => #_private; }',
        'unretained module reference',
      ),
      (
        'super',
        'class B { int f()=>1; } class A extends B { int g()=>super.f(); }',
        'class B { int f()=>1; } class A extends B { int g()=>super.f()+1; }',
        'super call',
      ),
      (
        'default-value',
        'class A { int f([int x=1])=>x; }',
        'class A { int f([int x=2])=>x; }',
        'incompatible Kernel library',
      ),
    ];
    for (final (name, before, after, diagnostic) in cases) {
      final directory = Directory('${root.path}/$name')..createSync();
      final base = File('${directory.path}/base.dart')
        ..writeAsStringSync(before);
      final updated = File('${directory.path}/updated.dart')
        ..writeAsStringSync(after);
      final entry = File('${directory.path}/main.dart')
        ..writeAsStringSync(
          "import 'base.dart';\n"
          "import '${spike.uri.resolve('dbc3_dispatch.dart')}';\n"
          'void main() {}\n',
        );
      final output = '${directory.path}/artifacts';
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${sdk.path}/.dart_tool/package_config.json',
        '${spike.path}/tool/compile_dbc3_patch.dart',
        sdk.path,
        base.path,
        updated.path,
        output,
        entry.path,
      ]);
      if (result.exitCode == 0 ||
          !'${result.stderr}'.contains(diagnostic) ||
          File('$output/patch.bytecode').existsSync()) {
        throw StateError(
          '$name gate failed: ${result.stdout}\n${result.stderr}',
        );
      }
      print('PASS: CFE rejects $name before bytecode emission');
    }
  } finally {
    root.deleteSync(recursive: true);
  }
}
