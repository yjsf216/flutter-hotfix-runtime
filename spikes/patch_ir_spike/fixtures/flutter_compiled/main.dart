import 'package:flutter/widgets.dart';

import '../../dbc3_dispatch.dart';
import 'baseline.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.length == 3) await bootSignedModule(arguments);
  runApp(const HotfixGreeting());
}
