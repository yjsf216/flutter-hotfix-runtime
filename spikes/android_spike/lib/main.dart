import 'package:flutter/material.dart';

const buildMarker = String.fromEnvironment(
  'HOTFIX_MARKER',
  defaultValue: 'BASELINE',
);

void main() => runApp(const MaterialApp(home: MarkerPage()));

class MarkerPage extends StatelessWidget {
  const MarkerPage({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Text(buildMarker, key: Key('build-marker'))),
  );
}
