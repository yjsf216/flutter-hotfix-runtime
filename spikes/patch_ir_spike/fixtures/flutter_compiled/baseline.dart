import 'package:flutter/widgets.dart';

class HotfixGreeting extends StatelessWidget {
  const HotfixGreeting({super.key});

  static String label(String value) => 'Flutter: $value';

  @override
  Widget build(BuildContext context) =>
      Text(label('baseline'), textDirection: TextDirection.ltr);
}
