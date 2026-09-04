import 'dart:io';

import 'package:dynamic_modules/dynamic_modules.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) throw ArgumentError('bytecode path required');
  try {
    final result = await loadModuleFromBytes(
      File(arguments.single).readAsBytesSync(),
    );
    if (result != 'base:patched-low!') {
      throw StateError('unexpected dynamic module result: $result');
    }
    print('PASS: upstream DBC3 module executes inside an AOT runtime');
  } on UnsupportedError {
    stderr.writeln('GAP: prebuilt AOT runtime has dart_dynamic_modules=false');
    exitCode = 78;
  }
}
