#!/bin/sh
set -eu

cd "$(dirname "$0")"
dart_bin=${DART_BIN:-dart}
"$dart_bin" format runtime.dart tool/build.dart fixtures
"$dart_bin" tool/build.dart
"$dart_bin" compile exe .dart_tool/generated_runner.dart -o .dart_tool/generated_runner
.dart_tool/generated_runner
