typedef PatchBody = Object? Function(List<Object?> arguments);

var _patches = <String, PatchBody>{};

void installPatches(Object? moduleResult) {
  if (moduleResult is! Map) throw StateError('patch module must return a map');
  final candidate = <String, PatchBody>{};
  for (final entry in moduleResult.entries) {
    if (entry.key is! String ||
        entry.key != Pricing.quoteId ||
        entry.value is! PatchBody) {
      throw StateError('invalid patch entry');
    }
    candidate[entry.key as String] = entry.value as PatchBody;
  }
  _patches = candidate;
}

class Pricing {
  static const quoteId = 'a9a6895bda6d60b5';

  int quote(int value) {
    final patch = _patches[quoteId];
    return patch == null ? value + 1 : patch(<Object?>[this, value]) as int;
  }

  static int tax(int value) => value + 7;
}
