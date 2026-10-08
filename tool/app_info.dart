// Read YAML with the same parser already used by the project compiler.
import 'dart:convert';
import 'dart:io';
import 'package:yaml/yaml.dart';

void main(List<String> args) {
  final spec = loadYaml(File(args.single).readAsStringSync()) as Map;
  print(jsonEncode({
    'version': spec['version'],
    'dependencies': (spec['dependencies'] as Map? ?? {}).keys.toList(),
    'overrides': (spec['dependency_overrides'] as Map? ?? {}).keys.toList(),
  }));
}
