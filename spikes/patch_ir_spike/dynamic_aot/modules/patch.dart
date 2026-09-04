import '../runtime_api.dart';

@pragma('dyn-module:entry-point')
Object? dynamicModuleEntrypoint() => <String, Object?>{
  'a9a6895bda6d60b5': (List<Object?> arguments) {
    final value = arguments[1] as int;
    final garbage = List<int>.generate(256, (index) => value + index);
    return Pricing.tax(garbage.first * 10);
  },
  'cb90885d5985e7f1': (List<Object?> _) =>
      throw StateError('interpreted failure'),
  '78753fc8e83d02be': (List<Object?> arguments) async {
    await Future<void>.delayed(Duration.zero);
    return Pricing.asyncTax((arguments[1] as int) * 10);
  },
};
