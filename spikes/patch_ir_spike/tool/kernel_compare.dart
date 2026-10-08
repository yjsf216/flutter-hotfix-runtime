import 'dart:typed_data';

import 'package:kernel/ast.dart';
import 'package:kernel/src/equivalence.dart';

/// Compare uninstrumented CFE procedures, including their signatures/defaults.
/// Only the explicitly paired libraries have interchangeable identities.
bool methodsEqual(
  Procedure before,
  Procedure after, {
  required Library baselineLibrary,
  required Library updatedLibrary,
  Map<Library, Library> libraryPairs = const {},
}) {
  final visitor = _Comparison(
    baselineLibrary,
    updatedLibrary,
    libraryPairs: libraryPairs,
  );
  visitor.seedLocals(before.function, after.function);
  final beforeClass = before.enclosingClass;
  final afterClass = after.enclosingClass;
  if (beforeClass != null && afterClass != null) {
    visitor.seedTypeParameters(
      beforeClass.typeParameters,
      afterClass.typeParameters,
    );
  }
  visitor.checkNodes(before, after, 'procedure');
  return visitor.toResult().isEquivalent;
}

/// Existing declaration structure must stay identical. Only existing concrete
/// procedure bodies and added static method helpers are permitted to differ.
/// Constructors and field initializers remain strict because they are not patched.
void checkLibraryCompatibility(
  Library baselineLibrary,
  Library updatedLibrary, {
  Map<Library, Library> libraryPairs = const {},
}) {
  final visitor = _Comparison(
    baselineLibrary,
    updatedLibrary,
    compatibility: true,
    libraryPairs: libraryPairs,
  );
  visitor.checkNodes(baselineLibrary, updatedLibrary, 'library');
  final result = visitor.toResult();
  if (!result.isEquivalent) {
    throw FormatException('incompatible Kernel library:\n$result');
  }
}

String _key(NamedNode node) {
  if (node is Library) return 'library';
  final parent = node.parent;
  final owner = parent is NamedNode ? _key(parent) : '';
  final name = node is Member
      ? node.name.text
      : node is Class
      ? node.name
      : node is Typedef
      ? node.name
      : node is Extension
      ? node.name
      : (node as ExtensionTypeDeclaration).name;
  return '$owner/${node.runtimeType}:${node is Procedure ? node.kind.name : ''}:$name';
}

class _Declarations extends RecursiveVisitor {
  final named = <String, NamedNode>{};
  final locals = <Node>[];

  @override
  void defaultTreeNode(TreeNode node) {
    if (node is NamedNode) {
      final key = _key(node);
      if (named.containsKey(key)) {
        throw FormatException('duplicate Kernel declaration: $key');
      }
      named[key] = node;
    }
    if (node is VariableDeclaration ||
        node is TypeParameter ||
        node is LabeledStatement ||
        node is SwitchCase) {
      locals.add(node);
    }
    node.visitChildren(this);
  }
}

final _bindingCache = Expando<_Bindings>();

class _Bindings {
  final references = <Reference, Reference>{};
  final declarations = <TypeParameter, TypeParameter>{};
  _Bindings(Map<Library, Library> pairs) {
    for (final pair in pairs.entries) {
      final left = _Declarations();
      final right = _Declarations();
      pair.value.accept(left);
      pair.key.accept(right);
      for (final entry in left.named.entries) {
        final other = right.named[entry.key];
        if (other == null) continue;
        references[entry.value.reference] = other.reference;
        if (entry.value is Field && other is Field) {
          final field = entry.value as Field;
          references[field.getterReference] = other.getterReference;
          final setter = field.setterReference;
          final otherSetter = other.setterReference;
          if (setter != null && otherSetter != null)
            references[setter] = otherSetter;
        }
        if (entry.value is Class && other is Class) {
          final parameters = (entry.value as Class).typeParameters;
          for (
            var i = 0;
            i < parameters.length && i < other.typeParameters.length;
            i++
          ) {
            declarations[parameters[i]] = other.typeParameters[i];
          }
        }
      }
    }
  }
}

class _Comparison extends EquivalenceVisitor {
  final Library baseline;
  final Library updated;
  late final _Bindings bindings;

  _Comparison(
    this.baseline,
    this.updated, {
    bool compatibility = false,
    Map<Library, Library> libraryPairs = const {},
  }) : super(strategy: _Strategy(compatibility)) {
    bindings = libraryPairs.isEmpty
        ? _Bindings({updated: baseline})
        : (_bindingCache[libraryPairs] ??= _Bindings(libraryPairs));
  }

  @override
  bool checkAssumedReferences(Reference? a, Reference? b) =>
      a != null && b != null && bindings.references[a] == b ||
      super.checkAssumedReferences(a, b);

  @override
  bool checkAssumedDeclarations(dynamic a, dynamic b) =>
      a is TypeParameter &&
          b is TypeParameter &&
          bindings.declarations[a] == b ||
      super.checkAssumedDeclarations(a, b);

  void seedTypeParameters(
    List<TypeParameter> before,
    List<TypeParameter> after,
  ) {
    for (var i = 0; i < before.length && i < after.length; i++) {
      assumeDeclarations(before[i], after[i]);
    }
  }

  void seedLocals(FunctionNode before, FunctionNode after) {
    final left = _Declarations();
    final right = _Declarations();
    before.accept(left);
    after.accept(right);
    for (var i = 0; i < left.locals.length && i < right.locals.length; i++) {
      assumeDeclarations(left.locals[i], right.locals[i]);
    }
  }

  @override
  bool checkValues<T>(T? a, T? b, String propertyName) {
    // Kernel Member documents these as nonserialized optimization hints that
    // may contain false positives. Bodies, initializers and ABI stay checked.
    if (propertyName == 'transformerFlags') return true;
    // These are diagnostic/serialization positions, never executable values.
    if (const {
      'fileUri',
      'fileOffset',
      'fileEndOffset',
      'fileStartOffset',
      'startFileOffset',
      'fileEqualsOffset',
      'conditionStartOffset',
      'conditionEndOffset',
      'bodyOffset',
      'binaryOffsetNoTag',
    }.contains(propertyName)) {
      return true;
    }
    if (propertyName == 'importUri' &&
        a == baseline.importUri &&
        b == updated.importUri) {
      return true;
    }
    // The upstream equality treats -0.0 == 0.0; Dart can observe their sign.
    if (a is double && b is double) {
      final bits = ByteData(16)
        ..setFloat64(0, a)
        ..setFloat64(8, b);
      return super.checkValues(
        bits.getUint64(0),
        bits.getUint64(8),
        propertyName,
      );
    }
    return super.checkValues(a, b, propertyName);
  }
}

class _Strategy extends EquivalenceStrategy {
  final bool compatibility;
  const _Strategy(this.compatibility);

  @override
  bool checkLibrary_additionalExports(
    EquivalenceVisitor visitor,
    Library node,
    Library other,
  ) {
    if (!visitor.checkValues(
      node.additionalExports.length,
      other.additionalExports.length,
      'additionalExports.length',
    ))
      return false;
    final remaining = List<Reference>.of(other.additionalExports);
    // ponytail: small export groups use matching; canonical-key multisets if large barrels become a bottleneck.
    for (final reference in node.additionalExports) {
      final index = remaining.indexWhere(
        (candidate) => visitor.matchReferences(reference, candidate),
      );
      if (index < 0) {
        visitor.registerInequivalence(
          'additionalExports',
          'Export target changed: $reference',
        );
        return false;
      }
      remaining.removeAt(index);
    }
    return true;
  }

  @override
  bool checkName(EquivalenceVisitor visitor, Name? node, Object? other) {
    if (node == null || other is! Name)
      return super.checkName(visitor, node, other);
    final textEqual = visitor.checkValues(node.text, other.text, 'text');
    final libraryEqual = visitor.checkReferences(
      node.libraryReference,
      other.libraryReference,
      'privateLibrary',
    );
    return textEqual && libraryEqual;
  }

  @override
  bool checkVariableGet_expressionVariable(
    EquivalenceVisitor visitor,
    VariableGet node,
    VariableGet other,
  ) => visitor.checkDeclarations(
    node.expressionVariable,
    other.expressionVariable,
    'variable',
  );

  @override
  bool checkVariableSet_expressionVariable(
    EquivalenceVisitor visitor,
    VariableSet node,
    VariableSet other,
  ) => visitor.checkDeclarations(
    node.expressionVariable,
    other.expressionVariable,
    'variable',
  );

  @override
  bool checkFunctionNode_body(
    EquivalenceVisitor visitor,
    FunctionNode node,
    FunctionNode other,
  ) {
    final owner = node.parent;
    if (compatibility &&
        owner is Procedure &&
        !owner.isAbstract &&
        !owner.isExternal &&
        !owner.isSynthetic &&
        owner.kind != ProcedureKind.Factory) {
      return visitor.checkValues(
        node.body == null,
        other.body == null,
        'bodyPresence',
      );
    }
    return super.checkFunctionNode_body(visitor, node, other);
  }

  bool _procedures(
    EquivalenceVisitor visitor,
    List<Procedure> before,
    List<Procedure> after,
  ) {
    if (!compatibility)
      return visitor.checkLists(
        before,
        after,
        visitor.checkNodes,
        'procedures',
      );
    final old = {for (final value in before) _key(value): value};
    final next = {for (final value in after) _key(value): value};
    for (final entry in old.entries) {
      visitor.checkNodes(
        entry.value,
        next[entry.key],
        'existingProcedure:${entry.key}',
      );
    }
    for (final entry in next.entries) {
      if (old.containsKey(entry.key)) continue;
      final helper = entry.value;
      if (!helper.isStatic ||
          helper.kind != ProcedureKind.Method ||
          helper.isExternal ||
          helper.isAbstract ||
          helper.isSynthetic ||
          helper.function.body == null) {
        visitor.registerInequivalence(
          'newProcedure',
          'only concrete static method helpers may be added: ${entry.key}',
        );
      }
    }
    return true;
  }

  @override
  bool checkClass_procedures(
    EquivalenceVisitor visitor,
    Class node,
    Class other,
  ) => _procedures(visitor, node.procedures, other.procedures);

  @override
  bool checkLibrary_procedures(
    EquivalenceVisitor visitor,
    Library node,
    Library other,
  ) => _procedures(visitor, node.procedures, other.procedures);
}
