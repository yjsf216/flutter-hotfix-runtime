import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:patch_ir_spike/dbc3_dispatch.dart';
import 'order_model.dart';
import 'order_repository.dart';
import 'order_view.dart';

Future<void> main(List<String> args) async {
  final binding = WidgetsFlutterBinding.ensureInitialized()..deferFirstFrame();
  const result = BasicMessageChannel<String>('hotfix/runtime-smoke', StringCodec());
  try {
    if (args.isNotEmpty && args.length != 4) throw ArgumentError('native host paths required');
    final patch = args.isEmpty ? null : await bootSignedModule(args.take(3).toList());
    final model = OrderModel(OrderRepository());
    await model.load();
    final amount = GlobalKey();
    runApp(OrderView(model: model, amountKey: amount));
    await binding.endOfFrame;
    final expected = patch == null ? 2400 : 2200;
    if ((amount.currentWidget as Text?)?.data != 'Total cents: $expected') {
      throw StateError('unexpected rendered order total');
    }
    binding.allowFirstFrame();
    await binding.waitUntilFirstFrameRasterized;
    if (patch != null && !commitModuleHealth(patch)) throw StateError('health commit failed');
    await result.send('PASS');
    await checkUpdatesAfterHealth(patch);
  } on Object catch (e) { await result.send('FAIL:$e'); }
}
