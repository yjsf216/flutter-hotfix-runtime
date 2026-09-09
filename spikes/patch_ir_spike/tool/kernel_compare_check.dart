import 'package:kernel/ast.dart';

import 'kernel_compare.dart';

Library fixture(String path) {
  final uri = Uri.parse('file:///$path.dart');
  final library = Library(uri, fileUri: uri);
  final first = VariableDeclaration('first');
  final second = VariableDeclaration('second', initializer: IntLiteral(7));
  final method = Procedure(
    Name('value'),
    ProcedureKind.Method,
    FunctionNode(
      ReturnStatement(VariableGet(first)),
      positionalParameters: [first, second],
      requiredParameterCount: 1,
    ),
    fileUri: uri,
  );
  final helper = Procedure(
    Name('_helper', library),
    ProcedureKind.Method,
    FunctionNode(ReturnStatement(IntLiteral(1))),
    isStatic: true,
    fileUri: uri,
  );
  final klass = Class(
    name: 'Service',
    fileUri: uri,
    fields: [
      Field.mutable(Name('state'), initializer: IntLiteral(0), fileUri: uri),
    ],
    constructors: [
      Constructor(FunctionNode(EmptyStatement()), name: Name(''), fileUri: uri),
    ],
    procedures: [method, helper],
    typeParameters: [TypeParameter('T')],
  );
  library.addClass(klass);
  return library;
}

Procedure method(Library library) => library.classes.single.procedures.first;

bool equal(Library before, Library after) => methodsEqual(
  method(before),
  method(after),
  baselineLibrary: before,
  updatedLibrary: after,
);

void check(bool value, String label) {
  if (!value) throw StateError(label);
}

void incompatible(String label, void Function(Library) change) {
  final before = fixture('before');
  final after = fixture('after');
  change(after);
  try {
    checkLibraryCompatibility(before, after);
  } on FormatException {
    return;
  }
  throw StateError('accepted $label');
}

void main() {
  final before = fixture('before');
  final after = fixture('after');
  method(after).fileOffset = 900;
  method(after).fileStartOffset = 890;
  method(after).fileEndOffset = 990;
  method(after).function.fileEndOffset = 980;
  method(after).function.positionalParameters[1].fileEqualsOffset = 950;
  check(equal(before, after), 'source URI/offset changed semantic equality');
  checkLibraryCompatibility(before, after);

  method(after).function.body = ReturnStatement(
    VariableGet(method(after).function.positionalParameters[1]),
  );
  check(!equal(before, after), 'parameter target swap was missed');
  checkLibraryCompatibility(before, after);

  for (final values in <List<Expression Function()>>[
    [() => IntLiteral(1), () => IntLiteral(2)],
    [() => StringLiteral('first'), () => StringLiteral('second')],
    [() => DoubleLiteral(0.0), () => DoubleLiteral(-0.0)],
    [
      () => ConstantExpression(DoubleConstant(0.0)),
      () => ConstantExpression(DoubleConstant(-0.0)),
    ],
  ]) {
    method(before).function.body = ReturnStatement(values[0]());
    method(after).function.body = ReturnStatement(values[1]());
    check(!equal(before, after), 'literal change was missed');
  }

  method(before).function.body = ReturnStatement(
    StaticInvocation(before.classes.single.procedures[1], Arguments([])),
  );
  method(after).function.body = ReturnStatement(
    StaticInvocation(after.classes.single.procedures[1], Arguments([])),
  );
  check(
    equal(before, after),
    'paired private member reference was not normalized',
  );
  final foreign = fixture('foreign');
  method(after).function.body = ReturnStatement(
    StaticInvocation(foreign.classes.single.procedures[1], Arguments([])),
  );
  check(!equal(before, after), 'foreign same-named call target was ignored');

  method(before).function.body = ReturnStatement(
    DynamicGet(
      DynamicAccessKind.Dynamic,
      ThisExpression(),
      Name('_secret', before),
    ),
  );
  method(after).function.body = ReturnStatement(
    DynamicGet(
      DynamicAccessKind.Dynamic,
      ThisExpression(),
      Name('_secret', foreign),
    ),
  );
  check(
    !equal(before, after),
    'private dynamic name lost its library identity',
  );

  Block shadowedBody(bool readInner) {
    final outer = VariableDeclaration('same', initializer: IntLiteral(1));
    final inner = VariableDeclaration('same', initializer: IntLiteral(1));
    return Block([
      outer,
      Block([inner, ReturnStatement(VariableGet(readInner ? inner : outer))]),
    ]);
  }

  method(before).function.body = shadowedBody(false);
  method(after).function.body = shadowedBody(false);
  check(equal(before, after), 'identical shadowed bindings differ');
  method(after).function.body = shadowedBody(true);
  check(!equal(before, after), 'same-named lexical binding swap was missed');

  LabeledStatement labelledBody(bool breakInner) {
    final outer = LabeledStatement(EmptyStatement());
    final inner = LabeledStatement(EmptyStatement());
    inner.body = BreakStatement(breakInner ? inner : outer)..parent = inner;
    outer.body = inner..parent = outer;
    return outer;
  }

  method(before).function.body = labelledBody(false);
  method(after).function.body = labelledBody(false);
  check(equal(before, after), 'identical labelled control flow differs');
  method(after).function.body = labelledBody(true);
  check(!equal(before, after), 'break target swap was missed');

  final added = fixture('after');
  added.classes.single.addProcedure(
    Procedure(
      Name('_new', added),
      ProcedureKind.Method,
      FunctionNode(ReturnStatement(StringLiteral('new'))),
      isStatic: true,
      fileUri: added.fileUri,
    ),
  );
  checkLibraryCompatibility(fixture('before'), added);

  incompatible(
    'field type',
    (lib) => lib.classes.single.fields.single.type = const VoidType(),
  );
  incompatible(
    'field initializer',
    (lib) => lib.classes.single.fields.single.initializer = IntLiteral(2),
  );
  incompatible(
    'static field',
    (lib) => lib.classes.single.fields.single.isStatic = true,
  );
  incompatible('field removal', (lib) => lib.classes.single.fields.clear());
  incompatible(
    'constructor body',
    (lib) => lib.classes.single.constructors.single.function.body =
        ReturnStatement(),
  );
  incompatible(
    'default parameter',
    (lib) => method(lib).function.positionalParameters[1].initializer =
        IntLiteral(8),
  );
  incompatible(
    'return type',
    (lib) => method(lib).function.returnType = const VoidType(),
  );
  incompatible(
    'generic bound',
    (lib) => lib.classes.single.typeParameters.single.bound =
        const NeverType.nonNullable(),
  );
  incompatible('class flags', (lib) => lib.classes.single.isAbstract = true);
  incompatible('enum conversion', (lib) => lib.classes.single.isEnum = true);
  incompatible(
    'supertype',
    (lib) => lib.classes.single.supertype = Supertype(
      fixture('external').classes.single,
      [const DynamicType()],
    ),
  );
  incompatible(
    'mixin type',
    (lib) => lib.classes.single.mixedInType = Supertype(
      fixture('external').classes.single,
      [const DynamicType()],
    ),
  );
  incompatible(
    'interface type',
    (lib) => lib.classes.single.implementedTypes.add(
      Supertype(fixture('external').classes.single, [const DynamicType()]),
    ),
  );
  incompatible(
    'method annotation',
    (lib) => method(lib).addAnnotation(StringLiteral('different')),
  );
  incompatible(
    'class annotation',
    (lib) => lib.classes.single.addAnnotation(StringLiteral('different')),
  );
  incompatible(
    'method removal',
    (lib) => lib.classes.single.procedures.removeAt(0),
  );
  incompatible(
    'new instance method',
    (lib) => lib.classes.single.addProcedure(
      Procedure(
        Name('newMethod'),
        ProcedureKind.Method,
        FunctionNode(EmptyStatement()),
        fileUri: lib.fileUri,
      ),
    ),
  );
  print(
    'PASS: Kernel semantic equality ignores positions but preserves literals, bindings and private names',
  );
  print(
    'PASS: Kernel compatibility enforces layout, constructors, defaults, generics, inheritance, enums and annotations',
  );
}
