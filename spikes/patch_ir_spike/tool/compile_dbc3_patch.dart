import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart2bytecode/bytecode_generator.dart' show generateBytecode;
import 'package:dart2bytecode/options.dart' show BytecodeOptions;
import 'package:front_end/src/api_prototype/file_system.dart' as front_end_fs;
import 'package:front_end/src/api_prototype/memory_file_system.dart';
import 'package:front_end/src/api_prototype/standard_file_system.dart';
import 'package:front_end/src/api_unstable/vm.dart' show CompilerOptions;
import 'package:front_end/src/base/hybrid_file_system.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/clone.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/kernel.dart';
import 'package:kernel/src/replacement_visitor.dart';
import 'package:kernel/type_algebra.dart';
import 'package:package_config/package_config.dart';
import 'package:vm/kernel_front_end.dart';
import 'package:vm/transformations/dynamic_interface_annotator.dart'
    show pragmaConstant;

import 'build.dart' show functionSignature, logicalLibraryUri;
import 'kernel_compare.dart';

const _defaultRetained = {'dart:core', 'dart:async', 'dart:_internal'};

/// Release and patch commands archive a baseline before any patch exists.
/// The combined command remains available for the earlier fixture scripts.
Future<void> main(List<String> args) async {
  final spike = File.fromUri(Platform.script).parent.parent;
  if (args.isNotEmpty &&
      args.first == 'release' &&
      (args.length == 4 || args.length == 5)) {
    await compileBaseline(
      sdk: Directory(args[1]).absolute,
      baselineUri: File(args[2]).absolute.uri,
      output: Directory(args[3]).absolute,
      entryUri: args.length == 5
          ? File(args[4]).absolute.uri
          : spike.uri.resolve('fixtures/compiled_entry.dart'),
    );
    return;
  }
  if (args.isNotEmpty && args.first == 'patch' && args.length == 5) {
    await compilePatch(
      sdk: Directory(args[1]).absolute,
      release: Directory(args[2]).absolute,
      updatedUri: File(args[3]).absolute.uri,
      output: Directory(args[4]).absolute,
    );
    return;
  }
  if (args.length < 4 || args.length > 5) {
    throw ArgumentError(
      'usage: release SDK BASELINE OUTPUT [ENTRY] | patch SDK RELEASE UPDATED OUTPUT | SDK BASELINE UPDATED OUTPUT [ENTRY]',
    );
  }
  final output = Directory(args[3]).absolute;
  await compileBaseline(
    sdk: Directory(args[0]).absolute,
    baselineUri: File(args[1]).absolute.uri,
    output: output,
    entryUri: args.length == 5
        ? File(args[4]).absolute.uri
        : spike.uri.resolve('fixtures/compiled_entry.dart'),
  );
  await compilePatch(
    sdk: Directory(args[0]).absolute,
    release: output,
    updatedUri: File(args[2]).absolute.uri,
    output: output,
  );
}

ErrorDetector _errors() => ErrorDetector(
  previousErrorHandler: (message) =>
      stderr.writeln(message.plainTextFormatted.join('\n')),
);

Future<String> _digestFile(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<Map<String, Object?>> _toolIdentity(
  Directory sdk,
  Uri platform, {
  Uri? genSnapshotUri,
}) async {
  final spike = File.fromUri(Platform.script).parent.parent;
  return {
    'compilerSources': {
      for (final name in [
        'compile_dbc3_patch.dart',
        'kernel_compare.dart',
        'build.dart',
      ])
        name: await _digestFile(File('${spike.path}/tool/$name')),
    },
    'genSnapshotSha256': await _digestFile(
      File.fromUri(
        genSnapshotUri ??
            sdk.uri.resolve('xcodebuild/ReleaseARM64/gen_snapshot_product'),
      ),
    ),
    'platformSha256': await _digestFile(File.fromUri(platform)),
    'snapshotKind': 'app-aot-elf',
  };
}

void _checkPatchable(Library library) {
  for (final procedure in _methods(library).values) {
    if (procedure.function.body == null) {
      throw FormatException('unsupported patch signature: ${procedure.name}');
    }
    final function = procedure.function;
    if ({
          AsyncMarker.SyncStar,
          AsyncMarker.AsyncStar,
        }.contains(function.dartAsyncMarker) &&
        (function.asyncMarker != function.dartAsyncMarker ||
            function.emittedValueType == null)) {
      throw const FormatException('generator Kernel markers are not intact');
    }
  }
}

Future<void> compileBaseline({
  required Directory sdk,
  required Uri baselineUri,
  required Uri entryUri,
  required Directory output,
  String targetName = 'vm',
  Uri? platformDillUri,
  Uri? packagesFileUri,
  Uri? genSnapshotUri,
  Set<Uri> retainedLibraries = const {},
  Map<String, String> environmentDefines = const {},
}) async {
  if (File('${output.path}/release.json').existsSync()) {
    throw const FormatException(
      'release already frozen; choose a new release directory',
    );
  }
  output.createSync(recursive: true);
  final spike = File.fromUri(Platform.script).parent.parent;
  final target = createFrontEndTarget(targetName, supportMirrors: false)!;
  final defines = <String, String>{
    'dart.vm.product': 'true',
    'dart.vm.profile': 'false',
    'HOTFIX_TEST_PUBLIC_KEY':
        Platform.environment['HOTFIX_TEST_PUBLIC_KEY'] ?? '',
    'HOTFIX_NATIVE_STORE':
        Platform.environment['HOTFIX_NATIVE_STORE'] ?? 'false',
    'HOTFIX_UPDATE_ORIGIN': Platform.environment['HOTFIX_UPDATE_ORIGIN'] ?? '',
    'HOTFIX_ALLOW_DEV_HTTP': Platform.environment['HOTFIX_ALLOW_DEV_HTTP'] ?? 'false',
    'HOTFIX_APP_ID': Platform.environment['HOTFIX_APP_ID'] ?? 'dev.hotfixruntime.fixture',
    'HOTFIX_PLATFORM': Platform.environment['HOTFIX_PLATFORM'] ?? 'host',
    ...environmentDefines,
  };
  retainedLibraries = {
    ..._defaultRetained.map(Uri.parse),
    ...retainedLibraries,
  };
  final errors = _errors();
  final options = CompilerOptions()
    ..sdkSummary =
        platformDillUri ??
        sdk.uri.resolve('xcodebuild/ReleaseARM64/vm_platform.dill')
    ..packagesFileUri =
        packagesFileUri ?? spike.uri.resolve('.dart_tool/package_config.json')
    ..target = target
    ..onDiagnostic = errors.call;
  final result = await compileToKernel(
    KernelCompilationArguments(
      source: entryUri,
      options: options,
      includePlatform: true,
      enableAsserts: false,
      environmentDefines: Map.of(defines),
    ),
  );
  final component = result.component;
  if (component == null || errors.hasCompilationErrors)
    throw StateError('frontend failed');
  final baseline = component.libraries.singleWhere(
    (lib) => lib.fileUri == baselineUri,
  );
  _checkPatchable(baseline);
  final core = CoreTypes(component);
  final previous = _methods(baseline);
  final ids = {
    for (final entry in previous.entries)
      entry.value: _id(Uri.parse(logicalLibraryUri), entry.key, entry.value),
  };
  final baseInput = '${output.path}/baseline.input.dill';
  await writeComponentToBinary(component, baseInput);
  final buildRecipe = <String, Object?>{
    ...await _toolIdentity(
      sdk,
      options.sdkSummary!,
      genSnapshotUri: genSnapshotUri,
    ),
    'baselineKernelSha256': await _digestFile(File(baseInput)),
    'logicalLibraryUri': logicalLibraryUri,
    'baselineLibraryUri': baseline.importUri.toString(),
    'entryUri': entryUri.toString(),
    'targetName': targetName,
    'retainedLibraries': retainedLibraries.map((uri) => uri.toString()).toList()
      ..sort(),
    'environmentDefines': defines,
  };
  final buildId = sha256
      .convert(utf8.encode(jsonEncode(buildRecipe)))
      .toString();
  final hooks = component.libraries.singleWhere(
    (lib) => lib.fileUri.path.endsWith('/patch_hook.dart'),
  );
  final hasPatch = hooks.procedures.singleWhere(
    (p) => p.name.text == 'hotfixHasPatch',
  );
  final invoke = hooks.procedures.singleWhere(
    (p) => p.name.text == 'hotfixInvoke',
  );
  final lookup = hooks.procedures.singleWhere(
    (p) => p.name.text == 'hotfixLookup',
  );
  for (final p in previous.values) {
    final original = p.function.body!;
    Expression patchCall = StaticInvocation(
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
    if (_patchTypeParameters(p).isNotEmpty) {
      final abi = _patchAbi(p, core);
      final types = _patchTypeParameters(
        p,
      ).map(TypeParameterType.withDefaultNullability).toList();
      patchCall = FunctionInvocation(
        FunctionAccessKind.FunctionType,
        AsExpression(
          StaticInvocation(lookup, Arguments([StringLiteral(ids[p]!)])),
          abi,
        ),
        Arguments(
          [
            if (!p.isStatic) ThisExpression(),
            for (final parameter in p.function.positionalParameters)
              VariableGet(parameter),
          ],
          types: types,
          named: [
            for (final parameter in p.function.namedParameters)
              NamedExpression(parameter.name!, VariableGet(parameter)),
          ],
        ),
        functionType: FunctionTypeInstantiator.instantiate(abi, types),
      );
    }
    final generator = {
      AsyncMarker.SyncStar,
      AsyncMarker.AsyncStar,
    }.contains(p.function.dartAsyncMarker);
    final patchedReturn = generator
        ? Block([
            YieldStatement(
              AsExpression(patchCall, p.function.returnType),
              isYieldStar: true,
            ),
            ReturnStatement(),
          ])
        : p.function.returnType is VoidType
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
  final buildField = runtime.fields.singleWhere(
    (f) => f.name.text == 'baselineBuildId',
  );
  buildField.initializer = StringLiteral(buildId)..parent = buildField;
  final validator = runtime.procedures.singleWhere(
    (p) => p.name.text == 'hotfixValidatePatch',
  );
  final equality = core.objectClass.procedures.singleWhere(
    (p) => p.name.text == '==',
  );
  validator.function.body = Block([
    for (final p in previous.values)
      IfStatement(
        EqualsCall(
          VariableGet(validator.function.positionalParameters[0]),
          StringLiteral(ids[p]!),
          functionType: equality.function.computeFunctionType(
            Nullability.nonNullable,
          ),
          interfaceTarget: equality,
        ),
        ReturnStatement(
          IsExpression(
            VariableGet(validator.function.positionalParameters[1]),
            _patchAbi(p, core),
          ),
        ),
        null,
      ),
    ReturnStatement(BoolLiteral(false)),
  ])..parent = validator.function;
  File('${output.path}/baseline.id').writeAsStringSync(buildId);
  final spec = File('${output.path}/dynamic_interface.yaml')
    ..writeAsStringSync(
      jsonEncode({
        'callable': [
          for (final uri in retainedLibraries) {'library': uri.toString()},
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
      source: entryUri,
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

  // Written last: consumers only accept a complete frozen release.
  File('${output.path}/release.json').writeAsStringSync(
    jsonEncode({
      'schemaVersion': 1,
      'baselineId': buildId,
      'buildRecipe': buildRecipe,
      'aotKernelSha256': await _digestFile(
        File('${output.path}/baseline.aot.dill'),
      ),
      'baselineFunctions': ids.values.toList(),
    }),
  );
  print(
    'PASS: frozen baseline $buildId with ${ids.length} automatic patch points',
  );
}

Future<void> compilePatch({
  required Directory sdk,
  required Directory release,
  required Uri updatedUri,
  required Directory output,
  Uri? platformDillUri,
  Uri? packagesFileUri,
  Uri? genSnapshotUri,
}) async {
  final spike = File.fromUri(Platform.script).parent.parent;
  final frozen =
      jsonDecode(File('${release.path}/release.json').readAsStringSync())
          as Map<String, dynamic>;
  if (frozen['schemaVersion'] != 1)
    throw const FormatException('unknown frozen release format');
  final recipe = frozen['buildRecipe'] as Map<String, dynamic>;
  final buildId = frozen['baselineId'] as String;
  final baseInput = File('${release.path}/baseline.input.dill');
  final platform =
      platformDillUri ??
      sdk.uri.resolve('xcodebuild/ReleaseARM64/vm_platform.dill');
  if (sha256.convert(utf8.encode(jsonEncode(recipe))).toString() != buildId ||
      File('${release.path}/baseline.id').readAsStringSync() != buildId ||
      await _digestFile(baseInput) != recipe['baselineKernelSha256']) {
    throw const FormatException('frozen baseline identity mismatch');
  }
  final toolIdentity = await _toolIdentity(
    sdk,
    platform,
    genSnapshotUri: genSnapshotUri,
  );
  for (final key in toolIdentity.keys) {
    if (jsonEncode(toolIdentity[key]) != jsonEncode(recipe[key])) {
      throw FormatException('frozen compiler/toolchain mismatch: $key');
    }
  }
  final candidateFile = File.fromUri(updatedUri);
  final baselineUri = Uri.parse(recipe['baselineLibraryUri'] as String);
  // CFE must see the candidate's original URI so URI-based `part of` directives
  // retain their ownership. Temporarily rename only the frozen Kernel library,
  // in memory; source files and the archived release are never rewritten.
  final frozenComponent = Component();
  BinaryBuilder(
    baseInput.readAsBytesSync(),
    disableLazyReading: true,
  ).readComponent(frozenComponent);
  final frozenLibrary = frozenComponent.libraries.singleWhere(
    (library) => library.importUri == baselineUri,
  );
  final frozenLibraryUri = Uri.parse('hotfix-baseline:$buildId/business.dart');
  frozenComponent.unbindCanonicalNames();
  frozenLibrary.importUri = frozenLibraryUri;
  frozenComponent.computeCanonicalNames();
  final memory = MemoryFileSystem(Uri.parse('hotfix-input:/'));
  final frozenInputUri = Uri.parse('hotfix-input:/baseline.dill');
  memory
      .entityForUri(frozenInputUri)
      .writeAsBytesSync(writeComponentToBytes(frozenComponent));
  final sourceUri = baselineUri;
  final packages =
      packagesFileUri ?? spike.uri.resolve('.dart_tool/package_config.json');
  final sourceFileUri = sourceUri.isScheme('package')
      ? (await loadPackageConfigUri(packages)).resolve(sourceUri)!
      : sourceUri;
  updatedUri = sourceUri;
  final target = createFrontEndTarget(
    recipe['targetName'] as String,
    supportMirrors: false,
  )!;
  final errors = _errors();
  final options = CompilerOptions()
    ..sdkSummary = platform
    ..packagesFileUri = packages
    ..fileSystem = HybridFileSystem(
      memory,
      _CandidateFileSystem(sourceFileUri, candidateFile.uri),
    )
    ..additionalDills = [frozenInputUri]
    ..target = target
    ..onDiagnostic = errors.call;
  final result = await compileToKernel(
    KernelCompilationArguments(
      source: sourceUri,
      options: options,
      requireMain: false,
      includePlatform: true,
      enableAsserts: false,
      environmentDefines: Map<String, String>.from(
        recipe['environmentDefines'] as Map,
      ),
    ),
  );
  final component = result.component;
  if (component == null || errors.hasCompilationErrors)
    throw StateError('candidate frontend failed');
  final retainedLibraries = (recipe['retainedLibraries'] as List)
      .cast<String>()
      .map(Uri.parse)
      .toSet();
  output.createSync(recursive: true);
  final baseline = component.libraries.singleWhere(
    (lib) => lib.importUri == frozenLibraryUri,
  );
  final updated = component.libraries.singleWhere(
    (lib) => lib.importUri == baselineUri,
  );
  // Hash the actual sources used by CFE, including parts (even when the entry
  // file is unchanged), rather than re-reading only the entry from disk.
  final sourceUris = component.uriToSource.keys.toList()
    ..sort((left, right) => left.toString().compareTo(right.toString()));
  final sourceBundleSha256 = sha256
      .convert(
        utf8.encode(
          jsonEncode({
            for (final uri in sourceUris)
              uri.toString(): sha256
                  .convert(component.uriToSource[uri]!.source)
                  .toString(),
          }),
        ),
      )
      .toString();
  // Imported dill bodies are lazy; load them before changing canonical names.
  component.accept(RecursiveVisitor());
  component.unbindCanonicalNames();
  updated.importUri = Uri.parse(
    'hotfix-candidate:$sourceBundleSha256/business.dart',
  );
  baseline.importUri = baselineUri;
  component.computeCanonicalNames();
  updatedUri = updated.importUri;
  final core = CoreTypes(component);
  final previous = _methods(baseline);
  final next = _methods(updated);
  final ids = {
    for (final e in previous.entries)
      e.value: _id(Uri.parse(logicalLibraryUri), e.key, e.value),
  };

  checkLibraryCompatibility(baseline, updated);
  final classMap = {
    for (final klass in updated.classes)
      klass: baseline.classes.singleWhere((old) => old.name == klass.name),
  };
  for (final e in previous.entries) {
    if (next[e.key] == null ||
        functionSignature(e.value) != functionSignature(next[e.key]!)) {
      throw FormatException('existing method signature changed: ${e.key}');
    }
  }
  _checkPatchable(baseline);
  _checkPatchable(updated);
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
    'hotfix:patch/$buildId/$sourceBundleSha256/module.dart',
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
    final classParameters = _classTypeParameters(e.key);
    final freshClass = getFreshTypeParameters(classParameters);
    final receiver = e.key.isStatic
        ? null
        : VariableDeclaration(
            'receiver',
            type: InterfaceType(
              classMap[e.key.enclosingClass]!,
              Nullability.nonNullable,
              freshClass.freshTypeArguments,
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
    cloner.typeSubstitution.addAll(
      Map.fromIterables(classParameters, freshClass.freshTypeArguments),
    );
    for (final parameter in freshClass.freshTypeParameters) {
      parameter.bound = cloner.visitType(parameter.bound);
      parameter.defaultType = cloner.visitType(parameter.defaultType);
    }
    final function = cloner.clone(e.key.function);
    function.typeParameters.insertAll(0, freshClass.freshTypeParameters);
    if (receiver != null) {
      function.positionalParameters.insert(0, receiver..parent = function);
      function.requiredParameterCount++;
    }
    e.value.function = function..parent = e.value;
    for (final parameter in freshClass.freshTypeParameters) {
      parameter.declaration = e.value;
    }
  }
  final exports = <MapLiteralEntry>[];
  for (final e in implementations.entries) {
    final old = previous[_key(e.key)];
    if (old == null) continue; // New helpers remain private to this module.
    if (_patchTypeParameters(e.key).isNotEmpty) {
      exports.add(
        MapLiteralEntry(
          StringLiteral(ids[old]!),
          ConstantExpression(StaticTearOffConstant(e.value)),
        ),
      );
      continue;
    }
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
        (lib) => retainedLibraries.contains(lib.importUri),
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

  File('${output.path}/metadata.json').writeAsStringSync(
    jsonEncode({
      'baselineId': buildId,
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
      'sourceBundleSha256': sourceBundleSha256,
      'artifactSha256': await _digestFile(
        File('${output.path}/patch.bytecode'),
      ),
    }),
  );
  print(
    'PASS: compiled ${exports.length} changed functions and ${implementations.length - exports.length} private helpers from frozen baseline',
  );
}

class _CandidateFileSystem implements front_end_fs.FileSystem {
  final Uri alias;
  final Uri source;
  _CandidateFileSystem(this.alias, this.source);

  @override
  front_end_fs.FileSystemEntity entityForUri(Uri uri) =>
      StandardFileSystem.instance.entityForUri(uri == alias ? source : uri);
}

FunctionType _patchAbi(Procedure procedure, CoreTypes core) {
  final parameters = _patchTypeParameters(procedure);
  if (parameters.isEmpty) {
    return FunctionType(
      [
        core.objectNullableRawType,
        InterfaceType(core.listClass, Nullability.nonNullable, [
          core.objectNullableRawType,
        ]),
      ],
      core.objectNullableRawType,
      Nullability.nonNullable,
    );
  }
  // Class and method binders form one scope: e.g. <T, U extends T>.
  final fresh = getFreshStructuralParametersFromTypeParameters(parameters);
  DartType substitute(DartType type) => fresh.substitution.substituteType(type);
  return FunctionType(
    [
      if (!procedure.isStatic)
        substitute(
          InterfaceType(
            procedure.enclosingClass!,
            Nullability.nonNullable,
            _classTypeParameters(
              procedure,
            ).map(TypeParameterType.withDefaultNullability).toList(),
          ),
        ),
      for (final parameter in procedure.function.positionalParameters)
        substitute(parameter.type),
    ],
    substitute(procedure.function.returnType),
    Nullability.nonNullable,
    typeParameters: fresh.freshTypeParameters,
    namedParameters: [
      for (final parameter in procedure.function.namedParameters)
        NamedType(
          parameter.name!,
          substitute(parameter.type),
          isRequired: parameter.isRequired,
        ),
    ]..sort(),
    requiredParameterCount:
        procedure.function.requiredParameterCount +
        (procedure.isStatic ? 0 : 1),
  );
}

List<TypeParameter> _classTypeParameters(Procedure procedure) =>
    procedure.isStatic ? const [] : procedure.enclosingClass!.typeParameters;

List<TypeParameter> _patchTypeParameters(Procedure procedure) => [
  ..._classTypeParameters(procedure),
  ...procedure.function.typeParameters,
];

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
