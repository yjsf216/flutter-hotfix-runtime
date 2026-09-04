import 'package:android_spike/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the compiled build marker', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MarkerPage()));
    expect(find.text('BASELINE'), findsOneWidget);
  });
}
