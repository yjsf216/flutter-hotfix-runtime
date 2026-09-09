import '../../dbc3_dispatch.dart';
import 'baseline.dart';

Future<void> main(List<String> arguments) async {
  final calculator = Calculator(5);
  final savedCall = calculator.quote;
  if (savedCall(3) != 17 || calculator.optional(3) != 6)
    throw StateError('baseline');
  final loaded = await bootSignedModule(arguments);
  if (loaded == null) throw StateError('signed generated patch rejected');
  if (savedCall(3) != 44 ||
      calculator.quote(3, extra: 9) != 51 ||
      calculator.nested() != 44 ||
      calculator.calls != 3 ||
      calculator.optional(3) != 60 ||
      calculator.optional(3, 4) != 120 ||
      await calculator.later(3) != 42 ||
      Calculator.tax(3) != 10) {
    throw StateError('generated patch semantics');
  }
  var caught = false;
  try {
    calculator.fail();
  } on StateError catch (error) {
    caught = error.message == 'interpreted failure';
  }
  if (!caught) throw StateError('exception');
  if (!commitModuleHealth(loaded)) throw StateError('healthy checkpoint');
  deactivateModule();
  if (savedCall(3) != 17 || calculator.calls != 3)
    throw StateError('rollback/object identity');
  print(
    'PASS: generated field/closure/named/optional/async/exception/nested-call patch + rollback',
  );
}
