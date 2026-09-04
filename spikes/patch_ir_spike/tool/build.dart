import 'dart:convert';
import 'dart:io';

import 'package:kernel/kernel.dart';

const logicalLibraryUri = 'package:patch_ir_spike/business.dart';

Future<void> main() async {
  final output = Directory('.dart_tool')..createSync(recursive: true);
  for (final name in [
    'baseline',
    'updated',
    'field_changed',
    'signature_changed',
  ]) {
    final source = File('fixtures/$name.dart').readAsStringSync();
    if (source.contains('@') ||
        source.contains('HotSwap') ||
        source.contains('register')) {
      throw StateError('business source must stay uninstrumented');
    }
    final entry = File('${output.path}/${name}_entry.dart')
      ..writeAsStringSync(
        "import '../fixtures/$name.dart';\n"
        'void main() { GreetingService(); }\n',
      );
    final result = Process.runSync(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      entry.path,
      '-o',
      '${output.path}/$name.dill',
      '--no-link-platform',
    ]);
    if (result.exitCode != 0) {
      stderr.write(result.stdout);
      stderr.write(result.stderr);
      exitCode = result.exitCode;
      return;
    }
  }

  final baseline = loadProgram('${output.path}/baseline.dill', 'baseline.dart');
  final updated = loadProgram('${output.path}/updated.dill', 'updated.dart');
  checkCompatible(baseline, updated);
  expectIncompatible(
    baseline,
    loadProgram('${output.path}/field_changed.dill', 'field_changed.dart'),
    'instance field layout',
  );
  expectIncompatible(
    baseline,
    loadProgram(
      '${output.path}/signature_changed.dill',
      'signature_changed.dart',
    ),
    'existing method signature',
  );
  print(
    'PASS: Kernel compatibility rejects field layout and signature changes',
  );

  final metadata = <String, Object?>{};
  for (final method in baseline.methods) {
    final next = updated.byId[method.functionId];
    if (next == null || next.signature != method.signature) {
      throw StateError('method signature changed: ${method.name}');
    }
    metadata[method.functionId] = {
      'classId': baseline.classId,
      'signature': method.signature,
      'isStatic': method.procedure.isStatic,
    };
  }

  final changed = <Map<String, Object?>>[];
  var changedBodies = 0;
  var newFunctions = 0;
  for (final method in updated.methods) {
    final old = baseline.byId[method.functionId];
    if (old == null) {
      newFunctions++;
      changed.add({
        'functionId': method.functionId,
        'signature': method.signature,
        'isNew': true,
        'isStatic': method.procedure.isStatic,
        'code': method.code,
      });
    } else if (jsonEncode(old.code) != jsonEncode(method.code)) {
      changedBodies++;
      changed.add({
        'functionId': method.functionId,
        'signature': method.signature,
        'code': method.code,
      });
    }
  }
  if (changedBodies != 1 || newFunctions != 1) {
    throw StateError('expected one changed and one new method');
  }

  final baselineId = stableId(
    [
      baseline.classId,
      ...baseline.methods.expand(
        (method) => [method.functionId, jsonEncode(method.code)],
      ),
    ].join('|'),
  );
  final identity = <String, Object?>{
    'appId': 'dev.hotfixruntime.fixture',
    'platform': 'android',
    'abi': 'arm64-v8a',
    'release': '1.0.0+1',
    'flutterRevision': '00b0c91f06209d9e4a41f71b7a512d6eb3b9c694',
    'dartVersion': '3.11.5',
    'engineRevision': '42d3d75a56',
    'flavor': 'production',
    'channel': 'stable',
    'buildParametersSha256':
        'd4ca340739925e8f4a854a9c4ed6069cc9f687c900a6c3eb509fa070cad0fbb4',
  };
  final patch = <String, Object?>{
    'baselineId': baselineId,
    'identity': identity,
    // ponytail: transport signature stub; platform crypto replaces this boundary next.
    'signature': 'valid-signature',
    'classes': [
      {'classId': baseline.classId, 'methods': changed},
    ],
  };

  File('${output.path}/generated_runner.dart').writeAsStringSync(
    generateRunner(baseline, baselineId, identity, metadata, patch),
  );
  await buildPatchPointDill(
    output,
    baseline,
    baselineId,
    identity,
    metadata,
    patch,
  );
}

Future<void> buildPatchPointDill(
  Directory output,
  KernelProgram baseline,
  String baselineId,
  Map<String, Object?> identity,
  Map<String, Object?> metadata,
  Map<String, Object?> patch,
) async {
  final bindings = baselineBindings(baseline);
  final identityJson = jsonEncode(identity);
  final metadataJson = jsonEncode(metadata);
  final patchJson = jsonEncode(patch);
  final entry = File('${output.path}/patch_point_entry.dart')
    ..writeAsStringSync('''
import 'dart:convert';
import '../fixtures/baseline.dart';
import '../fixtures/patch_hook.dart' as hook;
import '../runtime.dart';

void check(bool value) {
  if (!value) throw StateError('Kernel patch-point check failed');
}

void main() {
  final service = GreetingService();
  check(service.describe(15) == 'base:high');
  final metadata = (jsonDecode(r\'''$metadataJson\''') as Map<String, Object?>)
      .map((key, value) => MapEntry(key, value as Map<String, Object?>));
  final patch = jsonDecode(r\'''$patchJson\''') as Map<String, Object?>;
  final runtime = PatchRuntime(
    baselineId: '$baselineId',
    releaseIdentity: jsonDecode(r\'''$identityJson\''') as Map<String, Object?>,
    metadata: metadata,
    baselineFunctions: {$bindings},
  );
  check(runtime.install(patch));
  hook.isPatched = runtime.hasPatch;
  hook.dispatch = runtime.invoke;
  check(service.describe(15) == 'base:patched-low!');
  check(runtime.interpreterHits == 2 && runtime.baselineHits == 1);
  check(GreetingService.decorate('direct') == 'base:direct');
  check(runtime.interpreterHits == 2 && runtime.baselineHits == 1);
  print('PASS: transformed AOT entry -> changed IR -> baseline AOT/new IR');
}
''');
  final result = Process.runSync(Platform.resolvedExecutable, [
    'compile',
    'kernel',
    entry.path,
    '-o',
    '${output.path}/patch_point_input.dill',
  ]);
  if (result.exitCode != 0) {
    throw StateError('${result.stdout}\n${result.stderr}');
  }

  final component = loadComponentFromBinary(
    '${output.path}/patch_point_input.dill',
  );
  final business = component.libraries.singleWhere(
    (library) => library.fileUri.path.endsWith('baseline.dart'),
  );
  final hooks = component.libraries.singleWhere(
    (library) => library.fileUri.path.endsWith('patch_hook.dart'),
  );
  final hasPatch = hooks.procedures.singleWhere(
    (procedure) => procedure.name.text == 'hotfixHasPatch',
  );
  final invokePatch = hooks.procedures.singleWhere(
    (procedure) => procedure.name.text == 'hotfixInvoke',
  );
  final klass = business.classes.singleWhere(
    (value) => value.name == baseline.className,
  );
  for (final procedure in klass.procedures.where(
    (value) => !value.isSynthetic,
  )) {
    final original = procedure.function.body;
    if (original == null || procedure.function.namedParameters.isNotEmpty) {
      throw const FormatException('patch-point shape is the next gate');
    }
    final id = stableId('${baseline.classId}::${functionSignature(procedure)}');
    final patchCall = StaticInvocation(
      invokePatch,
      Arguments([
        StringLiteral(id),
        procedure.isStatic ? NullLiteral() : ThisExpression(),
        ListLiteral([
          for (final parameter in procedure.function.positionalParameters)
            VariableGet(parameter),
        ]),
      ]),
    );
    procedure.function.body = Block([
      IfStatement(
        StaticInvocation(hasPatch, Arguments([StringLiteral(id)])),
        ReturnStatement(AsExpression(patchCall, procedure.function.returnType)),
        null,
      ),
      original,
    ]);
  }
  await writeComponentToBinary(component, '${output.path}/patch_point.dill');
}

KernelProgram loadProgram(String dillPath, String sourceName) {
  final component = loadComponentFromBinary(dillPath);
  final library = component.libraries.singleWhere(
    (value) => value.fileUri.path.endsWith(sourceName),
  );
  final klass = library.classes.singleWhere(
    (value) => value.name == 'GreetingService',
  );
  final classId = stableId('$logicalLibraryUri::${klass.name}');
  final instanceFields = klass.fields
      .where((field) => !field.isStatic)
      .map(
        (field) => [
          field.name.text,
          field.type.getDisplayString(),
          field.isFinal,
          field.isLate,
        ].join('|'),
      )
      .toList();
  final program = KernelProgram(klass.name, classId, instanceFields);
  for (final procedure in klass.procedures.where(
    (value) => !value.isSynthetic,
  )) {
    final signature = functionSignature(procedure);
    final method = KernelMethod(
      procedure,
      stableId('$classId::$signature'),
      signature,
    );
    program.methods.add(method);
    program.byProcedure[procedure] = method;
  }
  for (final method in program.methods) {
    method.code = compileBody(method.procedure, program);
    program.byId[method.functionId] = method;
  }
  return program;
}

void checkCompatible(KernelProgram baseline, KernelProgram candidate) {
  if (baseline.classId != candidate.classId) {
    throw const FormatException('class identity changed');
  }
  if (jsonEncode(baseline.instanceFields) !=
      jsonEncode(candidate.instanceFields)) {
    throw const FormatException('instance field layout changed');
  }
  for (final old in baseline.methods) {
    final matches = candidate.methods.where(
      (method) =>
          method.name == old.name &&
          method.procedure.kind == old.procedure.kind &&
          method.procedure.isStatic == old.procedure.isStatic,
    );
    if (matches.length != 1 || matches.single.signature != old.signature) {
      throw FormatException('existing method signature changed: ${old.name}');
    }
  }
}

void expectIncompatible(
  KernelProgram baseline,
  KernelProgram candidate,
  String expected,
) {
  try {
    checkCompatible(baseline, candidate);
  } on FormatException catch (error) {
    if (error.message.toString().contains(expected)) return;
    rethrow;
  }
  throw StateError('$expected was accepted');
}

String functionSignature(Procedure procedure) {
  final function = procedure.function;
  final positional = function.positionalParameters
      .map((value) => value.type.getDisplayString())
      .join(',');
  final named = function.namedParameters
      .map(
        (value) =>
            '${value.name}:${value.type.getDisplayString()}:${value.isRequired}',
      )
      .join(',');
  final typeParameters = function.typeParameters
      .map((value) => value.bound.getDisplayString())
      .join(',');
  return [
    procedure.kind.name,
    procedure.isStatic ? 'static' : 'instance',
    procedure.name.text,
    '<$typeParameters>',
    'required=${function.requiredParameterCount}',
    'positional=($positional)',
    'named=($named)',
    'returns=${function.returnType.getDisplayString()}',
  ].join('|');
}

List<List<Object?>> compileBody(Procedure procedure, KernelProgram program) {
  final code = <List<Object?>>[];
  final body = procedure.function.body;
  if (body == null)
    throw FormatException('missing body: ${procedure.name.text}');
  compileStatement(body, procedure, program, code);
  if (code.isEmpty || code.last[0] != 'return') {
    throw FormatException('method must return: ${procedure.name.text}');
  }
  return code;
}

void compileStatement(
  Statement statement,
  Procedure owner,
  KernelProgram program,
  List<List<Object?>> code,
) {
  if (statement is Block) {
    for (final child in statement.statements) {
      compileStatement(child, owner, program, code);
    }
  } else if (statement is ReturnStatement) {
    compileExpression(statement.expression!, owner, program, code);
    code.add(['return']);
  } else if (statement is IfStatement) {
    if (statement.otherwise != null && statement.otherwise is! EmptyStatement) {
      throw const FormatException('else is the next gate');
    }
    compileExpression(statement.condition, owner, program, code);
    final jump = <Object?>['jumpIfFalse', 0];
    code.add(jump);
    compileStatement(statement.then, owner, program, code);
    jump[1] = code.length;
  } else {
    throw FormatException('unsupported statement ${statement.runtimeType}');
  }
}

void compileExpression(
  Expression expression,
  Procedure owner,
  KernelProgram program,
  List<List<Object?>> code,
) {
  if (expression is IntLiteral) {
    code.add(['const', expression.value]);
  } else if (expression is StringLiteral) {
    code.add(['const', expression.value]);
  } else if (expression is VariableGet) {
    final index = owner.function.positionalParameters.indexOf(
      expression.variable,
    );
    if (index < 0) throw const FormatException('locals are the next gate');
    code.add(['arg', index]);
  } else if (expression is InstanceInvocation &&
      const {'+', '>'}.contains(expression.name.text)) {
    compileExpression(expression.receiver, owner, program, code);
    if (expression.arguments.positional.length != 1) {
      throw const FormatException('binary arity');
    }
    compileExpression(
      expression.arguments.positional.single,
      owner,
      program,
      code,
    );
    code.add([expression.name.text == '+' ? 'add' : 'gt']);
  } else if (expression is StaticInvocation) {
    for (final argument in expression.arguments.positional) {
      compileExpression(argument, owner, program, code);
    }
    final target = program.byProcedure[expression.target];
    if (target == null)
      throw const FormatException('external calls are the next gate');
    code.add([
      'call',
      target.functionId,
      expression.arguments.positional.length,
    ]);
  } else {
    throw FormatException('unsupported expression ${expression.runtimeType}');
  }
}

String generateRunner(
  KernelProgram program,
  String baselineId,
  Map<String, Object?> identity,
  Map<String, Object?> metadata,
  Map<String, Object?> patch,
) {
  final bindings = baselineBindings(program, prefix: 'app.');
  final describe = program.byName('describe').functionId;
  final decorate = program.byName('decorate').functionId;
  final identityJson = jsonEncode(identity);
  final metadataJson = jsonEncode(metadata);
  final patchJson = jsonEncode(patch);
  return """
import 'dart:convert';
import '../fixtures/baseline.dart' as app;
import '../runtime.dart';

Map<String, Object?> clone(Map<String, Object?> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, Object?>;

void check(bool value) {
  if (!value) throw StateError('spike check failed');
}

PatchRuntime runtime(Map<String, Map<String, Object?>> metadata) => PatchRuntime(
  baselineId: '$baselineId',
  releaseIdentity: jsonDecode(r'''$identityJson''') as Map<String, Object?>,
  metadata: metadata,
  baselineFunctions: {$bindings},
);

void main() {
  final metadata = (jsonDecode(r'''$metadataJson''') as Map<String, Object?>)
      .map((key, value) => MapEntry(key, (value as Map<String, Object?>)));
  final patch = jsonDecode(r'''$patchJson''') as Map<String, Object?>;
  final receiver = app.${program.className}();

  final noPatch = runtime(metadata);
  check(noPatch.invoke('$describe', receiver, [15]) == 'base:high');
  check(noPatch.baselineHits == 1 && noPatch.interpreterHits == 0);

  final valid = runtime(metadata);
  check(valid.install(patch));
  check(valid.invoke('$describe', receiver, [15]) == 'base:patched-low!');
  check(valid.interpreterHits == 2 && valid.baselineHits == 1);
  check(valid.invoke('$decorate', null, ['direct']) == 'base:direct');

  final wrongBaseline = clone(patch)..['baselineId'] = 'wrong';
  final bad1 = runtime(metadata);
  check(!bad1.install(wrongBaseline));
  check(bad1.invoke('$describe', receiver, [15]) == 'base:high');

  final wrongSignature = clone(patch)..['signature'] = 'forged';
  final bad2 = runtime(metadata);
  check(!bad2.install(wrongSignature));
  check(bad2.invoke('$describe', receiver, [15]) == 'base:high');

  for (final key in (patch['identity'] as Map).keys) {
    final mismatch = clone(patch);
    (mismatch['identity'] as Map)[key] = 'mismatch';
    final rejected = runtime(metadata);
    check(!rejected.install(mismatch));
    check(rejected.invoke('$describe', receiver, [15]) == 'base:high');
  }

  final wrongMethod = clone(patch);
  final wrongMethods = ((wrongMethod['classes'] as List).first as Map)['methods'] as List;
  final existingMethod = wrongMethods.cast<Map>().singleWhere(
    (method) => method['isNew'] != true,
  );
  existingMethod['signature'] = 'changed signature';
  final bad3 = runtime(metadata);
  check(!bad3.install(wrongMethod));
  check(bad3.invoke('$describe', receiver, [15]) == 'base:high');

  final corrupt = clone(patch);
  final corruptMethods = ((corrupt['classes'] as List).first as Map)['methods'] as List;
  (corruptMethods.first as Map)['code'] = [['unknown-opcode'], ['return']];
  final bad4 = runtime(metadata);
  check(!bad4.install(corrupt));
  check(bad4.invoke('$describe', receiver, [15]) == 'base:high');

  print('PASS: Dart CFE Kernel -> stable IDs -> one changed + one new method IR');
  print('PASS: baseline AOT bindings + changed interpreter dispatch');
  print('PASS: wrong baseline/signature/method signature/corrupt IR -> baseline');
  print('PASS: every release identity mismatch -> baseline');
}
""";
}

String baselineBindings(KernelProgram program, {String prefix = ''}) => program
    .methods
    .map((method) {
      final function = method.procedure.function;
      final args = [
        for (var i = 0; i < function.positionalParameters.length; i++)
          'args[$i] as ${function.positionalParameters[i].type.getDisplayString()}',
      ].join(', ');
      final target = method.procedure.isStatic
          ? '$prefix${program.className}.${method.name}($args)'
          : '(receiver as $prefix${program.className}).${method.name}($args)';
      return "'${method.functionId}': (receiver, args) => $target";
    })
    .join(',\n');

class KernelProgram {
  KernelProgram(this.className, this.classId, this.instanceFields);
  final String className;
  final String classId;
  final List<String> instanceFields;
  final List<KernelMethod> methods = [];
  final Map<Procedure, KernelMethod> byProcedure = {};
  final Map<String, KernelMethod> byId = {};

  KernelMethod byName(String name) =>
      methods.singleWhere((method) => method.name == name);
}

class KernelMethod {
  KernelMethod(this.procedure, this.functionId, this.signature);
  final Procedure procedure;
  final String functionId;
  final String signature;
  late List<List<Object?>> code;
  String get name => procedure.name.text;
}

String stableId(String input) {
  // ponytail: 64-bit FNV proves determinism; use compiler-owned 128-bit IDs before production.
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = BigInt.parse('ffffffffffffffff', radix: 16);
  for (final byte in utf8.encode(input)) {
    hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
