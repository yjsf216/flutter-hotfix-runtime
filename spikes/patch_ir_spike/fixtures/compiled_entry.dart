import '../dbc3_dispatch.dart';
import 'baseline.dart';

Future<void> main(List<String> arguments) async {
  final service = GreetingService();
  final directCall = service.describe;
  if (directCall(15) != 'base:high') throw StateError('baseline');
  final loaded = await bootSignedModule(arguments.take(3).toList());
  if (arguments.length == 4 && arguments.last == 'expect-baseline') {
    if (loaded != null || directCall(15) != 'base:high')
      throw StateError('rejected patch changed baseline');
    print('PASS: forged generated patch manifest -> bundled baseline');
    return;
  }
  if (loaded == null) throw StateError('signed generated patch rejected');
  if (service.describe(15) != 'base:patched-low!' ||
      directCall(25) != 'base:patched-high!' ||
      GreetingService.decorate('unchanged') != 'base:unchanged') {
    throw StateError('compiled patch did not replace ordinary Dart method');
  }
  if (!commitModuleHealth(loaded)) throw StateError('healthy checkpoint');
  deactivateModule();
  if (directCall(15) != 'base:high') throw StateError('rollback');
  print(
    'PASS: ordinary Dart -> automatic patch points -> P-256 signed DBC3/store -> baseline AOT + rollback',
  );
}
