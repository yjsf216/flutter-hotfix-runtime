typedef BaselineFunction =
    Object? Function(Object? receiver, List<Object?> args);

class PatchRuntime {
  PatchRuntime({
    required this.baselineId,
    required this.metadata,
    required this.baselineFunctions,
  });

  final String baselineId;
  final Map<String, Map<String, Object?>> metadata;
  final Map<String, BaselineFunction> baselineFunctions;
  Map<String, List<List<Object?>>> _patch = const {};
  int baselineHits = 0;
  int interpreterHits = 0;

  Object? invoke(String functionId, Object? receiver, List<Object?> args) {
    final code = _patch[functionId];
    if (code != null) {
      interpreterHits++;
      return _interpret(code, receiver, args);
    }
    final baseline = baselineFunctions[functionId];
    if (baseline == null) throw StateError('unknown function $functionId');
    baselineHits++;
    return baseline(receiver, args);
  }

  bool install(Map<String, Object?> candidate) {
    try {
      if (candidate['baselineId'] != baselineId ||
          candidate['signature'] != 'valid-signature') {
        return false;
      }
      final next = <String, List<List<Object?>>>{};
      for (final classPatch in candidate['classes'] as List<Object?>) {
        final typedClass = classPatch as Map<String, Object?>;
        final classId = typedClass['classId'];
        final methods = typedClass['methods'] as List<Object?>;
        for (final value in methods) {
          final method = value as Map<String, Object?>;
          final id = method['functionId'] as String;
          if (metadata[id]?['classId'] != classId ||
              metadata[id]?['signature'] != method['signature']) {
            return false;
          }
          final code = (method['code'] as List<Object?>)
              .map((op) => (op as List<Object?>).toList())
              .toList();
          _validate(code);
          next[id] = code;
        }
      }
      _patch = next;
      return true;
    } on Object {
      return false;
    }
  }

  void _validate(List<List<Object?>> code) {
    if (code.isEmpty) throw const FormatException('empty IR');
    for (var pc = 0; pc < code.length; pc++) {
      final op = code[pc];
      if (op.isEmpty ||
          !const {
            'arg',
            'const',
            'add',
            'gt',
            'call',
            'jumpIfFalse',
            'return',
          }.contains(op[0])) {
        throw FormatException('bad opcode at $pc');
      }
      if (op[0] == 'arg' && (op.length != 2 || op[1] is! int)) {
        throw FormatException('bad arg at $pc');
      }
      if (op[0] == 'call' &&
          (op.length != 3 || metadata[op[1]] == null || op[2] is! int)) {
        throw FormatException('bad call at $pc');
      }
      if (op[0] == 'jumpIfFalse' &&
          (op.length != 2 ||
              op[1] is! int ||
              (op[1] as int) <= pc ||
              (op[1] as int) >= code.length)) {
        throw FormatException('bad jump at $pc');
      }
    }
    if (code.last[0] != 'return') throw const FormatException('missing return');
  }

  Object? _interpret(
    List<List<Object?>> code,
    Object? receiver,
    List<Object?> args,
  ) {
    final stack = <Object?>[];
    for (var pc = 0; pc < code.length; pc++) {
      final op = code[pc];
      switch (op[0]) {
        case 'arg':
          stack.add(args[op[1] as int]);
          break;
        case 'const':
          stack.add(op[1]);
          break;
        case 'add':
          final right = stack.removeLast();
          final left = stack.removeLast();
          stack.add(
            left is int && right is int
                ? left + right
                : '${left ?? ''}${right ?? ''}',
          );
          break;
        case 'gt':
          final right = stack.removeLast() as int;
          final left = stack.removeLast() as int;
          stack.add(left > right);
          break;
        case 'call':
          final count = op[2] as int;
          final callArgs = stack.sublist(stack.length - count);
          stack.removeRange(stack.length - count, stack.length);
          final target = op[1] as String;
          final targetReceiver = metadata[target]!['isStatic'] as bool
              ? null
              : receiver;
          stack.add(invoke(target, targetReceiver, callArgs));
          break;
        case 'jumpIfFalse':
          if (!(stack.removeLast() as bool)) pc = (op[1] as int) - 1;
          break;
        case 'return':
          return stack.removeLast();
        default:
          throw StateError('validated opcode missing implementation');
      }
    }
    throw StateError('IR did not return');
  }
}
