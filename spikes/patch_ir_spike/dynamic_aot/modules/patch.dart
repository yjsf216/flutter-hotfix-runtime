import '../runtime_api.dart';

@pragma('dyn-module:entry-point')
Object? dynamicModuleEntrypoint() => <String, Object?>{
  'a9a6895bda6d60b5': (List<Object?> arguments) {
    final value = arguments[1] as int;
    return Pricing.tax(value * 10);
  },
};
