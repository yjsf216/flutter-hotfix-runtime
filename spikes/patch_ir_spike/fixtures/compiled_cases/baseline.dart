class Calculator {
  final int _offset;
  int calls = 0;
  Calculator(this._offset);

  static int tax(int value) => value + 7;
  // Intentionally unused: the compiled candidate must reuse this AOT method.
  // ignore: unused_element
  static int _privateTax(int value) => value;
  int quote(int value, {int extra = 2}) => tax(value) + extra + _offset;
  int optional(int value, [int scale = 2]) => value * scale;
  int nested() => quote(3);
  Future<int> later(int value) async => tax(value);
  void fail() => throw StateError('baseline failure');
}
