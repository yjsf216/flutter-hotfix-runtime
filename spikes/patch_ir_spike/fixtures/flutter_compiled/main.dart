import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../../dbc3_dispatch.dart';
import 'baseline.dart';

Future<void> main(List<String> arguments) async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  // Do not let an empty frame during async patch loading satisfy startup health.
  binding.deferFirstFrame();
  const result = BasicMessageChannel<String>(
    'hotfix/runtime-smoke',
    StringCodec(),
  );
  try {
    final auto = arguments.length == 4 && arguments.last == 'auto';
    if (arguments.isNotEmpty &&
        arguments.length != 3 &&
        !(arguments.length == 4 &&
            (arguments.last == 'expect-baseline' || auto))) {
      throw ArgumentError(
        'module, manifest, store [expect-baseline|auto] required',
      );
    }
    final patch = arguments.isEmpty
        ? null
        : await bootSignedModule(arguments.take(3).toList());
    final expectBaseline = auto
        ? patch == null
        : arguments.isEmpty || arguments.length == 4;
    if (expectBaseline != (patch == null)) {
      throw StateError('unexpected signed-patch activation result');
    }
    final key = GlobalKey();
    runApp(HotfixGreeting(key: key));
    await binding.endOfFrame;
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
    if (binding.firstFrameRasterized) {
      throw StateError('first frame escaped the startup gate');
    }
    // endOfFrame only completes the Framework phase. Release the validated
    // Widget frame, then keep the boot pending until the Engine rasterizes it.
    binding.allowFirstFrame();
    await binding.waitUntilFirstFrameRasterized;
    if (!binding.firstFrameRasterized) {
      throw StateError('health checkpoint preceded first-frame rasterization');
    }
    if (patch != null && !commitModuleHealth(patch)) {
      throw StateError('signed patch did not pass the health checkpoint');
    }
    await result.send('PASS');
    await checkUpdatesAfterHealth(patch);
  } on Object catch (error) {
    await result.send('FAIL:$error');
  }
}
