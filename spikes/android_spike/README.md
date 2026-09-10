# android_spike

## Prebuilt hotfix baseline APK

This opt-in mode packages an already compiled Engine and frozen AOT baseline;
it skips Flutter Gradle plugins and `flutter assemble`. The default Flutter
build remains unchanged when `hotfix.prebuilt` is absent.

Prepare an absolute input directory with:

```text
lib/arm64-v8a/libflutter.so
lib/arm64-v8a/libapp.so
assets/flutter_assets/
```

Then run from `android/`:

```sh
./gradlew :app:assembleRelease --offline --max-workers=2 \
  -Photfix.prebuilt=/absolute/path/to/staged-inputs
```

The native store is built by CMake; do not supply a second copy in the input.
Output: `build/prebuilt-app/outputs/apk/release/app-release.apk` relative to this
Flutter project. It is arm64-only and debug-signed. Packaging/byte checks passed;
device execution and application-side patch bootstrap remain unverified.
See [recorded evidence](../../engine/EVIDENCE.md#android-development-apk-packaging-gate-passed).

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
