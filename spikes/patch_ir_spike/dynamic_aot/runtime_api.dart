typedef PatchBody = Object? Function(List<Object?> arguments);

var _patches = <String, PatchBody>{};

void installPatches(Object? moduleResult) {
  if (moduleResult is! Map) throw StateError('patch module must return a map');
  final candidate = <String, PatchBody>{};
  for (final entry in moduleResult.entries) {
    if (entry.key is! String ||
        !Pricing.patchIds.contains(entry.key) ||
        entry.value is! PatchBody) {
      throw StateError('invalid patch entry');
    }
    candidate[entry.key as String] = entry.value as PatchBody;
  }
  _patches = candidate;
}

class Pricing {
  static const quoteId = 'a9a6895bda6d60b5';
  static const failId = 'cb90885d5985e7f1';
  static const asyncId = '78753fc8e83d02be';
  static const patchIds = {quoteId, failId, asyncId};

  int quote(int value) {
    final patch = _patches[quoteId];
    return patch == null ? value + 1 : patch(<Object?>[this, value]) as int;
  }

  static int tax(int value) => value + 7;

  void fail() => _patches[failId]?.call(<Object?>[this]);

  Future<int> asyncQuote(int value) {
    final patch = _patches[asyncId];
    return patch == null
        ? Future<int>.value(value + 1)
        : patch(<Object?>[this, value]) as Future<int>;
  }

  static Future<int> asyncTax(int value) async => value + 7;
}
