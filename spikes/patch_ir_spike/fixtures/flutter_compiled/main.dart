import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../../dbc3_dispatch.dart';
import 'baseline.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  const result = BasicMessageChannel<String>(
    'hotfix/runtime-smoke',
    StringCodec(),
  );
  try {
    if (arguments.isNotEmpty &&
        arguments.length != 3 &&
        !(arguments.length == 4 && arguments.last == 'expect-baseline')) {
      throw ArgumentError('module, manifest, store [expect-baseline] required');
    }
    final expectBaseline = arguments.isEmpty || arguments.length == 4;
    final patch = arguments.isEmpty
        ? null
        : await bootSignedModule(arguments.take(3).toList());
    if (expectBaseline != (patch == null)) {
      throw StateError('unexpected signed-patch activation result');
    }
    final key = GlobalKey();
    runApp(HotfixGreeting(key: key));
    await WidgetsBinding.instance.endOfFrame;
    final context = key.currentContext;
    if (context == null) throw StateError('Widget was not mounted');
    String? text;
    // Read the actual mounted child; do not invoke build again as a substitute
    // for proving that the Framework consumed the patched Widget result.
    context.visitChildElements((child) {
      final widget = child.widget;
      if (widget is Text) text = widget.data;
    });
    final expected = expectBaseline ? 'Flutter: baseline' : 'Flutter: patched';
    if (text != expected) throw StateError('mounted Text differs: $text');
    if (patch != null && !commitModuleHealth(patch)) {
      throw StateError('signed patch did not pass the health checkpoint');
    }
    await result.send('PASS');
  } on Object catch (error) {
    await result.send('FAIL:$error');
  }
}
