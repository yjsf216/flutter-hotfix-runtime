import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart2bytecode/bytecode_generator.dart' show generateBytecode;
import 'package:dart2bytecode/options.dart' show BytecodeOptions;
import 'package:front_end/src/api_unstable/vm.dart' show CompilerOptions;
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/clone.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/kernel.dart';
import 'package:kernel/src/replacement_visitor.dart';
import 'package:vm/kernel_front_end.dart';
import 'package:vm/transformations/dynamic_interface_annotator.dart'
    show pragmaConstant;

import 'build.dart' show functionSignature, logicalLibraryUri;
import 'kernel_compare.dart';

/// Host driver for the pinned frontend. All executable patch bodies come from
/// cloned Kernel; business sources are never rewritten or manually registered.
Future<void> main(List<String> arguments) async {
  if (arguments.length < 4 || arguments.length > 5) {
    throw ArgumentError(
      'usage: compile_dbc3_patch sdk-source baseline updated output [host-entry]',
    );
  }
  final sdk = Directory(arguments[0]).absolute;
  final baselineUri = File(arguments[1]).absolute.uri;
  final updatedUri = File(arguments[2]).absolute.uri;
  final output = Directory(arguments[3]).absolute..createSync(recursive: true);
  final spike = File.fromUri(Platform.script).parent.parent;
  final hostUri = arguments.length == 5
      ? File(arguments[4]).absolute.uri
      : spike.uri.resolve('fixtures/compiled_entry.dart');
  final target = createFrontEndTarget('vm', supportMirrors: false)!;
  final defines = <String, String>{
    'dart.vm.product': 'true',
    'dart.vm.profile': 'false',
    'HOTFIX_TEST_PUBLIC_KEY':
        Platform.environment['HOTFIX_TEST_PUBLIC_KEY'] ?? '',
  };
  final errors = ErrorDetector(
    previousErrorHandler: (message) =>
        stderr.writeln(message.plainTextFormatted.join('\n')),
  );
  final options = CompilerOptions()
    ..sdkSummary = sdk.uri.resolve('xcodebuild/ReleaseARM64/vm_platform.dill')
    ..packagesFileUri = spike.uri.resolve('.dart_tool/package_config.json')
    ..target = target
    ..onDiagnostic = errors.call;
  final result = await compileToKernel(
    KernelCompilationArguments(
      source: hostUri,
      options: options,
      includePlatform: true,
      enableAsserts: false,
      environmentDefines: Map.of(defines),
    ),
  );
  final hostComponent = result.component;
  if (hostComponent == null || errors.hasCompilationErrors)
    throw StateError('frontend failed');
  final baseInput = '${output.path}/baseline.input.dill';
  await writeComponentToBinary(hostComponent, baseInput);
  final patchOptions = CompilerOptions()
    ..sdkSummary = options.sdkSummary
    ..packagesFileUri = options.packagesFileUri
    ..additionalDills = [File(baseInput).uri]
    ..target = target
    ..onDiagnostic = errors.call;
  final patchResult = await compileToKernel(
    KernelCompilationArguments(
      source: updatedUri,
      options: patchOptions,
      requireMain: false,
      includePlatform: true,
      enableAsserts: false,
      environmentDefines: Map.of(defines),
    ),
  );
  var component = patchResult.component;
  if (component == null || errors.hasCompilationErrors)
    throw StateError('candidate frontend failed');
  final baseline = component.libraries.singleWhere(
    (lib) => lib.fileUri == baselineUri,
  );
  final updated = component.libraries.singleWhere(
    (lib) => lib.fileUri == updatedUri,
  );
  var core = CoreTypes(component);
  var previous = _methods(baseline);
  final next = _methods(updated);
  var ids = {
    for (final e in previous.entries)
      e.value: _id(Uri.parse(logicalLibraryUri), e.key, e.value),
  };

  checkLibraryCompatibility(baseline, updated);
  final classMap = {
    for (final klass in updated.classes)
      klass: baseline.classes.singleWhere((old) => old.name == klass.name),
  };
  if (classMap.keys.any((klass) => klass.typeParameters.isNotEmpty)) {
    throw const FormatException(
      'generic class patch lowering is not implemented',
    );
  }
  for (final e in previous.entries) {
    if (next[e.key] == null ||
        functionSignature(e.value) != functionSignature(next[e.key]!)) {
      throw FormatException('existing method signature changed: ${e.key}');
    }
  }
  for (final procedure in [...previous.values, ...next.values]) {
    if ({
          AsyncMarker.SyncStar,
          AsyncMarker.AsyncStar,
        }.contains(procedure.function.dartAsyncMarker) ||
        {
          AsyncMarker.SyncStar,
          AsyncMarker.AsyncStar,
        }.contains(procedure.function.asyncMarker)) {
      throw const FormatException(
        'generator patch points require yield forwarding',
      );
    }
    if (procedure.function.typeParameters.isNotEmpty ||
        procedure.function.body == null) {
      throw FormatException('unsupported patch signature: ${procedure.name}');
    }
  }
  final changed = <Procedure>[];
  for (final e in next.entries) {
    final old = previous[e.key];
    if (old == null ||
        !methodsEqual(
          old,
          e.value,
          baselineLibrary: baseline,
          updatedLibrary: updated,
        )) {
      if (old == null && !e.value.isStatic)
        throw const FormatException('new instance method');
      changed.add(e.value);
    }
  }
  if (changed.isEmpty) throw const FormatException('no changed functions');

  final moduleUri = Uri.parse(
    'hotfix:patch/${sha256.convert(File.fromUri(updatedUri).readAsBytesSync())}/module.dart',
  );
  final module = Library(moduleUri, fileUri: updatedUri)..parent = component;
  final implementations = <Procedure, Procedure>{};
  for (final original in changed) {
    final key = _key(original);
    final id =
        ids[previous[key]] ?? _id(Uri.parse(logicalLibraryUri), key, original);
    final implementation = Procedure(
      Name('patch_$id'),
      ProcedureKind.Method,
      FunctionNode(null),
      isStatic: true,
      fileUri: updatedUri,
    );
    module.addProcedure(implementation);
    implementations[original] = implementation;
  }
  for (final e in implementations.entries) {
    final receiver = e.key.isStatic
        ? null
        : VariableDeclaration(
            'receiver',
            type: InterfaceType(
              classMap[e.key.enclosingClass]!,
              Nullability.nonNullable,
            ),
          );
    final cloner = _PatchCloner(
      updated,
      baseline,
      previous,
      implementations,
      receiver,
      classMap,
    );
    final function = cloner.clone(e.key.function);
    if (receiver != null) {
      function.positionalParameters.insert(0, receiver..parent = function);
      function.requiredParameterCount++;
    }
    e.value.function = function..parent = e.value;
  }
  final exports = <MapLiteralEntry>[];
  for (final e in implementations.entries) {
    final old = previous[_key(e.key)];
    if (old == null) continue; // New helpers remain private to this module.
    final receiver = VariableDeclaration(
      'receiver',
      type: core.objectNullableRawType,
    );
    final args = VariableDeclaration(
      'args',
      type: InterfaceType(core.listClass, Nullability.nonNullable, [
        core.objectNullableRawType,
      ]),
    );
    final indexer = core.listClass.procedures.singleWhere(
      (p) => p.name.text == '[]',
    );
    final parameters = [
      ...e.key.function.positionalParameters,
      ...e.key.function.namedParameters,
    ];
    Expression argument(int i) => AsExpression(
      InstanceInvocation(
        InstanceAccessKind.Instance,
        VariableGet(args),
        Name('[]'),
        Arguments([IntLiteral(i)]),
        functionType: FunctionType(
          [core.intNonNullableRawType],
          core.objectNullableRawType,
          Nullability.nonNullable,
        ),
        interfaceTarget: indexer,
      ),
      _Types(classMap).map(parameters[i].type),
    );
    final invocation = StaticInvocation(
      e.value,
      Arguments(
        [
          if (!e.key.isStatic)
            AsExpression(
              VariableGet(receiver),
              InterfaceType(
                classMap[e.key.enclosingClass]!,
                Nullability.nonNullable,
              ),
            ),
          for (var i = 0; i < e.key.function.positionalParameters.length; i++)
            argument(i),
        ],
        named: [
          for (var i = 0; i < e.key.function.namedParameters.length; i++)
            NamedExpression(
              e.key.function.namedParameters[i].name!,
              argument(e.key.function.positionalParameters.length + i),
            ),
        ],
      ),
    );
    final body = e.key.function.returnType is VoidType
        ? Block([
            ExpressionStatement(invocation),
            ReturnStatement(NullLiteral()),
          ])
        : ReturnStatement(invocation);
    exports.add(
      MapLiteralEntry(
        StringLiteral(ids[old]!),
        FunctionExpression(
          FunctionNode(
            body,
            positionalParameters: [receiver, args],
            requiredParameterCount: 2,
            returnType: core.objectNullableRawType,
          ),
        ),
      ),
    );
  }
  final entry = Procedure(
    Name('patchEntry'),
    ProcedureKind.Method,
    FunctionNode(
      ReturnStatement(
        MapLiteral(
          exports,
          keyType: core.stringNonNullableRawType,
          valueType: core.objectNullableRawType,
        ),
      ),
      returnType: core.objectNullableRawType,
    ),
    isStatic: true,
    fileUri: updatedUri,
  );
  module.addProcedure(entry);
  component.libraries.add(module);
  module.accept(
    _ModuleBoundary({
      module,
      baseline,
      ...component.libraries.where(
        (lib) => {
          'dart:core',
          'dart:async',
          'dart:_internal',
        }.contains(lib.importUri.toString()),
      ),
    }),
  );
  component.setMainMethodAndMode(entry.reference, true);
  component.computeCanonicalNames();
  final sink = File('${output.path}/patch.bytecode').openWrite();
  generateBytecode(
    component,
    sink,
    libraries: [module],
    coreTypes: core,
    hierarchy: ClassHierarchy(component, core),
    target: target,
    options: BytecodeOptions(),
  );
  await sink.close();
  // The baseline is emitted from its independent compilation. No candidate
  // declarations, constants or bodies can become baseline AOT code.
  component = hostComponent;
  core = CoreTypes(component);
  previous = _methods(
    component.libraries.singleWhere((lib) => lib.fileUri == baselineUri),
  );
  ids = {
    for (final e in previous.entries)
      e.value: _id(Uri.parse(logicalLibraryUri), e.key, e.value),
  };

  final hooks = component.libraries.singleWhere(
    (lib) => lib.fileUri.path.endsWith('/patch_hook.dart'),
  );
  final hasPatch = hooks.procedures.singleWhere(
    (p) => p.name.text == 'hotfixHasPatch',
  );
  final invoke = hooks.procedures.singleWhere(
    (p) => p.name.text == 'hotfixInvoke',
  );
  for (final p in previous.values) {
    final original = p.function.body!;
    final patchCall = StaticInvocation(
      invoke,
      Arguments([
        StringLiteral(ids[p]!),
        p.isStatic ? NullLiteral() : ThisExpression(),
        ListLiteral([
          for (final parameter in [
            ...p.function.positionalParameters,
            ...p.function.namedParameters,
          ])
            VariableGet(parameter),
        ], typeArgument: core.objectNullableRawType),
      ]),
    );
    final patchedReturn = p.function.returnType is VoidType
        ? Block([ExpressionStatement(patchCall), ReturnStatement()])
        : ReturnStatement(AsExpression(patchCall, p.function.returnType));
    p.function.body = Block([
      IfStatement(
        StaticInvocation(hasPatch, Arguments([StringLiteral(ids[p]!)])),
        patchedReturn,
        null,
      ),
      original,
    ])..parent = p.function;
    p.addAnnotation(
      ConstantExpression(pragmaConstant(core, 'vm:never-inline')),
    );
  }
  final runtime = component.libraries.singleWhere(
    (lib) => lib.fileUri.path.endsWith('/dbc3_dispatch.dart'),
  );
  final idField = runtime.fields.singleWhere(
    (f) => f.name.text == 'baselinePatchIds',
  );
  idField.initializer = StringLiteral(ids.values.join(','))..parent = idField;
  final buildRecipe = <String, Object?>{
    'baselineKernelSha256': sha256
        .convert(File(baseInput).readAsBytesSync())
        .toString(),
    'compilerSources': {
      for (final name in [
        'compile_dbc3_patch.dart',
        'kernel_compare.dart',
        'build.dart',
      ])
        name: sha256
            .convert(File('${spike.path}/tool/$name').readAsBytesSync())
            .toString(),
    },
    'genSnapshotSha256':
        (await sha256
                .bind(
                  File(
                    '${sdk.path}/xcodebuild/ReleaseARM64/gen_snapshot_product',
                  ).openRead(),
                )
                .first)
            .toString(),
    'snapshotKind': 'app-aot-elf',
    'logicalLibraryUri': logicalLibraryUri,
  };
  final buildId = sha256
      .convert(utf8.encode(jsonEncode(buildRecipe)))
      .toString();
  final buildField = runtime.fields.singleWhere(
    (f) => f.name.text == 'baselineBuildId',
  );
  buildField.initializer = StringLiteral(buildId)..parent = buildField;
  File('${output.path}/baseline.id').writeAsStringSync(buildId);
  final spec = File('${output.path}/dynamic_interface.yaml')
    ..writeAsStringSync(
      jsonEncode({
        'callable': [
          {'library': 'dart:core'},
          {'library': 'dart:async'},
          {'library': baseline.importUri.toString()},
          // Library-wide annotation skips private declarations. Retain them
          // explicitly so a future patch can call a previously unused member.
          for (final klass in baseline.classes) ...[
            {'library': baseline.importUri.toString(), 'class': klass.name},
            for (final member in [
              ...klass.constructors,
              ...klass.procedures,
              ...klass.fields,
            ])
              {
                'library': baseline.importUri.toString(),
                'class': klass.name,
                'member': member.name.text,
              },
          ],
          for (final member in [...baseline.procedures, ...baseline.fields])
            {
              'library': baseline.importUri.toString(),
              'member': member.name.text,
            },
        ],
      }),
    );
  await runGlobalTransformations(
    target,
    component,
    errors,
    KernelCompilationArguments(
      source: hostUri,
      options: options,
      aot: true,
      includePlatform: true,
      useGlobalTypeFlowAnalysis: true,
      dynamicInterface: spec.uri,
      enableAsserts: false,
      environmentDefines: Map.of(defines),
    ),
  );
  if (errors.hasCompilationErrors) throw StateError('AOT transform failed');
  await writeComponentToBinary(component, '${output.path}/baseline.aot.dill');
  File('${output.path}/metadata.json').writeAsStringSync(
    jsonEncode({
      'baselineId': buildId,
      'buildRecipe': buildRecipe,
      'baselineFunctions': ids.values.toList(),
      'changed': [
        for (final p in changed.where((p) => previous.containsKey(_key(p))))
          ids[previous[_key(p)]],
      ],
      'newHelpers': [
        for (final p in changed.where((p) => !previous.containsKey(_key(p))))
          _key(p),
      ],
      'moduleLibraries': [moduleUri.toString()],
    }),
  );
  print(
    'PASS: compiled ${exports.length} changed functions and ${implementations.length - exports.length} private helpers to DBC3',
  );
}

String _key(Procedure p) =>
    '${p.enclosingClass?.name ?? ''}::${p.kind.name}::${p.name.text}';
Map<String, Procedure> _methods(Library lib) => {
  for (final klass in lib.classes)
    for (final p in klass.procedures.where((p) => !p.isSynthetic)) _key(p): p,
  for (final p in lib.procedures.where((p) => !p.isSynthetic)) _key(p): p,
};
String _id(Uri library, String key, Procedure p) => sha256
    .convert(utf8.encode('$library::$key::${functionSignature(p)}'))
    .toString()
    .substring(0, 32);

class _PatchCloner extends CloneVisitorNotMembers {
  _PatchCloner(
    this.updated,
    this.baselineLibrary,
    this.baseline,
    this.implementations,
    this.receiver,
    Map<Class, Class> classes,
  ) : types = _Types(classes);
  final Library updated;
  final Library baselineLibrary;
  final Map<String, Procedure> baseline;
  final Map<Procedure, Procedure> implementations;
  final VariableDeclaration? receiver;
  final _Types types;

  Member _member(Member member) {
    if (member.enclosingLibrary != updated) return member;
    if (member is Procedure) {
      final target = baseline[_key(member)] ?? implementations[member];
      if (target != null) return target;
    } else {
      final owner = member.enclosingClass == null
          ? null
          : types.classes[member.enclosingClass]!;
      if (member is Field)
        return (owner?.fields ?? baselineLibrary.fields).singleWhere(
          (f) => f.name.text == member.name.text,
        );
      if (member is Constructor)
        return owner!.constructors.singleWhere(
          (c) => c.name.text == member.name.text,
        );
    }
    throw FormatException('unresolved member: ${member.name}');
  }

  Name _name(Name name) => name.isPrivate && name.library == updated
      ? Name(name.text, baselineLibrary)
      : name;

  @override
  DartType visitType(DartType type) => types.map(super.visitType(type));

  @override
  DartType? visitOptionalType(DartType? type) =>
      type == null ? null : visitType(type);

  @override
  TreeNode visitThisExpression(ThisExpression node) => VariableGet(receiver!);

  @override
  TreeNode visitStaticInvocation(StaticInvocation node) {
    return StaticInvocation(
      _member(node.target) as Procedure,
      clone(node.arguments),
      isConst: node.isConst,
    );
  }

  @override
  TreeNode visitConstructorInvocation(ConstructorInvocation node) =>
      ConstructorInvocation(
        _member(node.target) as Constructor,
        clone(node.arguments),
        isConst: node.isConst,
      );

  @override
  TreeNode visitStaticGet(StaticGet node) => StaticGet(_member(node.target));

  @override
  TreeNode visitStaticSet(StaticSet node) =>
      StaticSet(_member(node.target), clone(node.value));

  @override
  TreeNode visitStaticTearOff(StaticTearOff node) =>
      StaticTearOff(_member(node.target) as Procedure);

  @override
  TreeNode visitInstanceGet(InstanceGet node) => InstanceGet(
    node.kind,
    clone(node.receiver),
    _name(node.name),
    resultType: visitType(node.resultType),
    interfaceTarget: _member(node.interfaceTarget),
  );

  @override
  TreeNode visitInstanceSet(InstanceSet node) => InstanceSet(
    node.kind,
    clone(node.receiver),
    _name(node.name),
    clone(node.value),
    interfaceTarget: _member(node.interfaceTarget),
  );

  @override
  TreeNode visitInstanceInvocation(InstanceInvocation node) =>
      InstanceInvocation(
        node.kind,
        clone(node.receiver),
        _name(node.name),
        clone(node.arguments),
        functionType: visitType(node.functionType) as FunctionType,
        interfaceTarget: _member(node.interfaceTarget) as Procedure,
      )..flags = node.flags;
}

class _Types extends ReplacementVisitor {
  _Types(this.classes);
  final Map<Class, Class> classes;
  DartType map(DartType type) => type.accept1(this, Variance.covariant) ?? type;
  @override
  DartType? createInterfaceType(
    InterfaceType node,
    Nullability? nullability,
    List<DartType>? arguments,
  ) {
    final target = classes[node.classNode];
    return target == null
        ? super.createInterfaceType(node, nullability, arguments)
        : InterfaceType(
            target,
            nullability ?? node.nullability,
            arguments ?? node.typeArguments,
          );
  }
}

/// Any unsupported rebinding fails compilation, before bytecode reaches a VM.
class _ModuleBoundary extends RecursiveVisitor {
  _ModuleBoundary(this.allowed);
  final Set<Library> allowed;
  void _check(Library library) {
    if (!allowed.contains(library))
      throw FormatException(
        'unretained module reference: ${library.importUri}',
      );
  }

  @override
  void defaultMemberReference(Member node) => _check(node.enclosingLibrary);
  @override
  void visitClassReference(Class node) => _check(node.enclosingLibrary);
  @override
  void visitName(Name node) {
    if (node.library != null) _check(node.library!);
  }

  @override
  void visitSymbolConstantReference(SymbolConstant node) {
    if (node.libraryReference != null) _check(node.libraryReference!.asLibrary);
  }

  @override
  void visitDynamicInvocation(DynamicInvocation node) =>
      throw const FormatException(
        'dynamic invocation cannot be checked against baseline interface',
      );
  @override
  void visitDynamicGet(DynamicGet node) => throw const FormatException(
    'dynamic getter cannot be checked against baseline interface',
  );
  @override
  void visitDynamicSet(DynamicSet node) => throw const FormatException(
    'dynamic setter cannot be checked against baseline interface',
  );
  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) =>
      throw const FormatException('super call requires lexical class lowering');
  @override
  void visitSuperPropertyGet(SuperPropertyGet node) =>
      throw const FormatException(
        'super getter requires lexical class lowering',
      );
  @override
  void visitSuperPropertySet(SuperPropertySet node) =>
      throw const FormatException(
        'super setter requires lexical class lowering',
      );
  @override
  void defaultConstantReference(Constant node) => node.visitChildren(this);
}
