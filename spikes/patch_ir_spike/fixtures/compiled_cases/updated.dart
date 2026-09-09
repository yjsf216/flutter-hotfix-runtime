class Calculator {
  final int _offset;
  int calls = 0;
  Calculator(this._offset);

  static int tax(int value) => value + 7;
  static int _privateTax(int value) => value;
  static int multiply(int value) => value * 10;
  int quote(int value, {int extra = 2}) {
    calls++;
    final values = List<int>.generate(4, (index) => value + index);
    return tax(multiply(values.first)) + extra + _offset + _privateTax(0);
  }

  int optional(int value, [int scale = 2]) => multiply(value) * scale;
  int nested() => quote(3);
  Future<int> later(int value) async {
    await Future<void>.value();
    return tax(multiply(value)) + _offset;
  }

  void fail() => throw StateError('interpreted failure');
}
