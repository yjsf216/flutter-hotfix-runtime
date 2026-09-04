import 'dart:convert';
import 'dart:io';

void main() {
  final baselineSource = File('fixtures/baseline.dart').readAsStringSync();
  final updatedSource = File('fixtures/updated.dart').readAsStringSync();
  for (final source in [baselineSource, updatedSource]) {
    if (source.contains('@') ||
        source.contains('HotSwap') ||
        source.contains('register')) {
      throw StateError('business source must stay uninstrumented');
    }
  }

  final baseline = parseProgram(baselineSource);
  final updated = parseProgram(updatedSource);
  if (baseline.classId != updated.classId) throw StateError('unstable ClassId');

  final metadata = <String, Object?>{};
  for (final method in baseline.methods) {
    final next = updated.methods
        .where((value) => value.functionId == method.functionId)
        .toList();
    if (next.length != 1 || next.single.signature != method.signature) {
      throw StateError('method signature changed: ${method.name}');
    }
    metadata[method.functionId] = {
      'classId': baseline.classId,
      'signature': method.signature,
      'isStatic': method.isStatic,
    };
  }

  final changed = <Map<String, Object?>>[];
  for (final method in updated.methods) {
    final old = baseline.methods
        .where((value) => value.functionId == method.functionId)
        .single;
    if (old.normalizedBody != method.normalizedBody) {
      changed.add({
        'functionId': method.functionId,
        'signature': method.signature,
        'code': compileMethod(method, updated),
      });
    }
  }
  if (changed.length != 1) throw StateError('expected one changed method');

  final baselineId = stableId(
    [
      baseline.classId,
      ...baseline.methods.expand(
        (method) => [method.functionId, method.normalizedBody],
      ),
    ].join('|'),
  );
  final patch = <String, Object?>{
    'baselineId': baselineId,
    // ponytail: transport signature stub; platform crypto replaces this boundary next.
    'signature': 'valid-signature',
    'classes': [
      {'classId': baseline.classId, 'methods': changed},
    ],
  };

  final output = Directory('.dart_tool')..createSync(recursive: true);
  File(
    '${output.path}/generated_runner.dart',
  ).writeAsStringSync(generateRunner(baseline, baselineId, metadata, patch));
}

String generateRunner(
  Program program,
  String baselineId,
  Map<String, Object?> metadata,
  Map<String, Object?> patch,
) {
  final bindings = program.methods
      .map((method) {
        final args = [
          for (var i = 0; i < method.parameterTypes.length; i++)
            'args[$i] as ${method.parameterTypes[i]}',
        ].join(', ');
        final target = method.isStatic
            ? 'app.${program.className}.${method.name}($args)'
            : '(receiver as app.${program.className}).${method.name}($args)';
        return "'${method.functionId}': (receiver, args) => $target";
      })
      .join(',\n');
  final describe = program.methods
      .singleWhere((method) => method.name == 'describe')
      .functionId;
  final decorate = program.methods
      .singleWhere((method) => method.name == 'decorate')
      .functionId;
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
  check(valid.invoke('$describe', receiver, [15]) == 'base:patched-low');
  check(valid.interpreterHits == 1 && valid.baselineHits == 1);
  check(valid.invoke('$decorate', null, ['direct']) == 'base:direct');

  final wrongBaseline = clone(patch)..['baselineId'] = 'wrong';
  final bad1 = runtime(metadata);
  check(!bad1.install(wrongBaseline));
  check(bad1.invoke('$describe', receiver, [15]) == 'base:high');

  final wrongSignature = clone(patch)..['signature'] = 'forged';
  final bad2 = runtime(metadata);
  check(!bad2.install(wrongSignature));
  check(bad2.invoke('$describe', receiver, [15]) == 'base:high');

  final wrongMethod = clone(patch);
  final wrongMethods = ((wrongMethod['classes'] as List).first as Map)['methods'] as List;
  (wrongMethods.first as Map)['signature'] = 'changed signature';
  final bad3 = runtime(metadata);
  check(!bad3.install(wrongMethod));
  check(bad3.invoke('$describe', receiver, [15]) == 'base:high');

  final corrupt = clone(patch);
  final corruptMethods = ((corrupt['classes'] as List).first as Map)['methods'] as List;
  (corruptMethods.first as Map)['code'] = [['unknown-opcode'], ['return']];
  final bad4 = runtime(metadata);
  check(!bad4.install(corrupt));
  check(bad4.invoke('$describe', receiver, [15]) == 'base:high');

  print('PASS: ordinary Dart -> stable IDs -> one-method Patch IR -> AOT/interpreter dispatch');
  print('PASS: wrong baseline/signature/method signature/corrupt IR -> baseline');
}
""";
}

class Program {
  Program(this.className, this.classId, this.methods);
  final String className;
  final String classId;
  final List<Method> methods;
}

class Method {
  Method({
    required this.name,
    required this.returnType,
    required this.parameterTypes,
    required this.parameterNames,
    required this.isStatic,
    required this.body,
    required this.functionId,
    required this.signature,
  });
  final String name;
  final String returnType;
  final List<String> parameterTypes;
  final List<String> parameterNames;
  final bool isStatic;
  final String body;
  final String functionId;
  final String signature;
  String get normalizedBody => body.replaceAll(RegExp(r'\s+'), ' ').trim();
}

Program parseProgram(String source) {
  // ponytail: fixture-only parser; replace with upstream Dart frontend after this semantic gate.
  final classMatch = RegExp(r'class\s+(\w+)\s*\{').firstMatch(source);
  if (classMatch == null) throw const FormatException('one class required');
  final className = classMatch.group(1)!;
  const libraryUri = 'package:patch_ir_spike/business.dart';
  final classId = stableId('$libraryUri::$className');
  final open = source.indexOf('{', classMatch.start);
  final close = matchingBrace(source, open);
  final body = source.substring(open + 1, close);
  final header = RegExp(r'(static\s+)?(\w+)\s+(\w+)\s*\(([^)]*)\)\s*(=>|\{)');
  final methods = <Method>[];
  var offset = 0;
  while (true) {
    final match = header.firstMatch(body.substring(offset));
    if (match == null) break;
    final start = match.start + offset;
    final end = match.end + offset;
    final marker = match.group(5)!;
    late String methodBody;
    late int next;
    if (marker == '=>') {
      next = body.indexOf(';', end);
      if (next < 0) throw const FormatException('missing semicolon');
      methodBody = body.substring(end, next);
      next++;
    } else {
      final brace = body.indexOf('{', start);
      final methodClose = matchingBrace(body, brace);
      methodBody = body.substring(brace + 1, methodClose);
      next = methodClose + 1;
    }
    final params = match.group(4)!.trim();
    final parameterTypes = <String>[];
    final parameterNames = <String>[];
    if (params.isNotEmpty) {
      for (final parameter in params.split(',')) {
        final parts = parameter.trim().split(RegExp(r'\s+'));
        if (parts.length != 2)
          throw const FormatException('simple parameters only');
        parameterTypes.add(parts[0]);
        parameterNames.add(parts[1]);
      }
    }
    final name = match.group(3)!;
    final isStatic = match.group(1) != null;
    final signature =
        '${match.group(2)} $name(${parameterTypes.join(',')}) ${isStatic ? 'static' : 'instance'}';
    methods.add(
      Method(
        name: name,
        returnType: match.group(2)!,
        parameterTypes: parameterTypes,
        parameterNames: parameterNames,
        isStatic: isStatic,
        body: methodBody,
        signature: signature,
        functionId: stableId('$classId::$signature'),
      ),
    );
    offset = next;
  }
  if (methods.isEmpty) throw const FormatException('no methods');
  return Program(className, classId, methods);
}

int matchingBrace(String source, int open) {
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return i;
  }
  throw const FormatException('unclosed brace');
}

List<List<Object?>> compileMethod(Method method, Program program) {
  final ifReturn = RegExp(
    r'^\s*if\s*\((.*?)\)\s*return\s+(.*?);\s*return\s+(.*?);\s*$',
    dotAll: true,
  ).firstMatch(method.body);
  final code = <List<Object?>>[];
  void expression(String source) => compileExpression(
    ExpressionParser(source).parse(),
    method,
    program,
    code,
  );
  if (ifReturn == null) {
    expression(method.body);
    code.add(['return']);
    return code;
  }
  expression(ifReturn.group(1)!);
  final jump = ['jumpIfFalse', 0];
  code.add(jump);
  expression(ifReturn.group(2)!);
  code.add(['return']);
  jump[1] = code.length;
  expression(ifReturn.group(3)!);
  code.add(['return']);
  return code;
}

void compileExpression(
  Expr expr,
  Method method,
  Program program,
  List<List<Object?>> code,
) {
  if (expr is LiteralExpr) {
    code.add(['const', expr.value]);
  } else if (expr is NameExpr) {
    final index = method.parameterNames.indexOf(expr.name);
    if (index < 0) throw FormatException('unknown name ${expr.name}');
    code.add(['arg', index]);
  } else if (expr is BinaryExpr) {
    compileExpression(expr.left, method, program, code);
    compileExpression(expr.right, method, program, code);
    code.add([expr.operator == '+' ? 'add' : 'gt']);
  } else if (expr is CallExpr) {
    for (final argument in expr.arguments) {
      compileExpression(argument, method, program, code);
    }
    final target = program.methods.singleWhere(
      (value) =>
          value.name == expr.name &&
          value.parameterNames.length == expr.arguments.length,
    );
    code.add(['call', target.functionId, expr.arguments.length]);
  } else {
    throw StateError('expression compiler incomplete');
  }
}

abstract class Expr {}

class LiteralExpr extends Expr {
  LiteralExpr(this.value);
  final Object value;
}

class NameExpr extends Expr {
  NameExpr(this.name);
  final String name;
}

class BinaryExpr extends Expr {
  BinaryExpr(this.left, this.operator, this.right);
  final Expr left;
  final String operator;
  final Expr right;
}

class CallExpr extends Expr {
  CallExpr(this.name, this.arguments);
  final String name;
  final List<Expr> arguments;
}

class ExpressionParser {
  ExpressionParser(String source) : tokens = tokenize(source);
  final List<String> tokens;
  var index = 0;

  Expr parse() {
    final result = comparison();
    if (index != tokens.length)
      throw FormatException('unexpected ${tokens[index]}');
    return result;
  }

  Expr comparison() {
    var result = additive();
    if (take('>')) result = BinaryExpr(result, '>', additive());
    return result;
  }

  Expr additive() {
    var result = primary();
    while (take('+')) result = BinaryExpr(result, '+', primary());
    return result;
  }

  Expr primary() {
    if (take('(')) {
      final result = comparison();
      expect(')');
      return result;
    }
    if (index >= tokens.length)
      throw const FormatException('expression expected');
    final token = tokens[index++];
    if (token.startsWith("'"))
      return LiteralExpr(token.substring(1, token.length - 1));
    final number = int.tryParse(token);
    if (number != null) return LiteralExpr(number);
    if (take('(')) {
      final arguments = <Expr>[];
      if (!take(')')) {
        do {
          arguments.add(comparison());
        } while (take(','));
        expect(')');
      }
      return CallExpr(token, arguments);
    }
    return NameExpr(token);
  }

  bool take(String token) {
    if (index < tokens.length && tokens[index] == token) {
      index++;
      return true;
    }
    return false;
  }

  void expect(String token) {
    if (!take(token)) throw FormatException('$token expected');
  }
}

List<String> tokenize(String source) {
  final result = <String>[];
  for (var i = 0; i < source.length;) {
    final char = source[i];
    if (RegExp(r'\s').hasMatch(char)) {
      i++;
      continue;
    }
    if (char == "'") {
      final end = source.indexOf("'", i + 1);
      if (end < 0) throw const FormatException('unclosed string');
      result.add(source.substring(i, end + 1));
      i = end + 1;
    } else if (RegExp(r'[A-Za-z_]').hasMatch(char)) {
      var end = i + 1;
      while (end < source.length &&
          RegExp(r'[A-Za-z0-9_]').hasMatch(source[end]))
        end++;
      result.add(source.substring(i, end));
      i = end;
    } else if (RegExp(r'[0-9]').hasMatch(char)) {
      var end = i + 1;
      while (end < source.length && RegExp(r'[0-9]').hasMatch(source[end]))
        end++;
      result.add(source.substring(i, end));
      i = end;
    } else if ('()+>,'.contains(char)) {
      result.add(char);
      i++;
    } else {
      throw FormatException('unsupported character $char');
    }
  }
  return result;
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
