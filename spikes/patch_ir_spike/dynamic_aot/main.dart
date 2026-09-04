import 'dart:io';

import 'package:dynamic_modules/dynamic_modules.dart';

import 'runtime_api.dart';

Future<void> main() async {
  final pricing = Pricing();
  if (pricing.quote(3) != 4) throw StateError('baseline dispatch failed');

  var rejected = false;
  try {
    installPatches(<String, PatchBody>{
      Pricing.quoteId: (_) => 99,
      'unknown': (_) => 100,
    });
  } on StateError {
    rejected = true;
  }
  if (!rejected) throw StateError('invalid table was accepted');
  if (pricing.quote(3) != 4) {
    throw StateError('invalid table was partially installed');
  }

  installPatches(
    await loadModuleFromBytes(
      File('modules/patch.dart.bytecode').readAsBytesSync(),
    ),
  );

  if (pricing.quote(3) != 37) throw StateError('patched dispatch failed');
  print('PASS: FunctionId AOT -> interpreted closure -> baseline AOT');
}
