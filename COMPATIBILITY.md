# Compatibility and support matrix

“Planned” and “source-confirmed” are not support claims.

| Platform | Toolchain baseline | ABI | Status | Largest open check |
|---|---|---|---|---|
| Android | Flutter 3.41.9, Dart 3.11.5, Engine `42d3d75a56` | arm64-v8a | finite device AOT/DBC3 + online delivery verified | broader apps, semantics, fault tests and production operations |
| Android | same | armeabi-v7a, x86_64 | planned | interpreter portability and performance |
| iOS | same pinned Flutter/Dart baseline | arm64 | finite personal-signed device AOT/DBC3 + online delivery verified | broader apps, fault tests and App Review |
| OHOS/HarmonyOS | Flutter 3.27.5-ohos-1.0.5, Dart 3.6.2, Engine `e672b006cb` | ohos-arm64 first | research only | shared Runtime port through ArkTS/N-API and market policy |

## Compatibility rule

A patch is compatible only when every signed identity field equals the running release. No semver ranges, revision prefixes, ABI aliases, or “close enough” Flutter versions are accepted. A patch cannot change native plugins, assets, Engine, Dart SDK, build defines, obfuscation inputs, split-debug-info inputs, flavor, or release channel unless those inputs are part of an identically reproduced store release.

## Required test record per platform/ABI/release

1. clean baseline build and install;
2. valid signed patch cold start;
3. truncated and bit-flipped artifact;
4. invalid/unknown/revoked signing key;
5. each identity field mismatched independently;
6. interrupted download and interrupted atomic install;
7. no network, read-only/full disk, and stale manifest;
8. crash before and after launch-success checkpoint;
9. server withdrawal with cached candidate;
10. last-known-good loss, falling back to bundled code.

## Known limitations

- Only Patch IR Dart changes within the declared compatibility boundary are in scope; native plugin and asset changes require a store release.
- Engine/VM snapshot formats are treated as private, exact-revision contracts.
- First-launch update is intentionally not supported; downloads occur without blocking the current known-good launch.
- iOS implementation passes the documented finite device matrix; production and App Review gates remain open.
- Project CLI currently supports one explicitly selected patchable Dart library.
  Other lib sources, declared assets/fonts, native source/configuration and dependency
  metadata are guarded. This is not arbitrary multi-library hot reload.
- The order example has widget tests and target-specific baseline/patch compilation;
  its own new physical-device online matrix is separate from the earlier greeting demo.
- Store acceptance varies by behavior and jurisdiction; technical success does not establish compliance.

## Historical evidence snapshot (2026-09-04; superseded by device records)

- Installed Android target: Flutter 3.41.9, framework `00b0c91f06`, Dart 3.11.5, Engine `42d3d75a56`.
- Installed OHOS target: Flutter 3.27.5-ohos-1.0.5, framework `d9cf54be36`, Dart 3.6.2, Engine `e672b006cb`.
- Connected devices are outside this task's scope. Device evidence must be supplied by an authorized operator.
- OHOS release artifacts are expected to contain `libapp.so` based on the supplied project context and public OpenHarmony engine loader; this repository has not yet rebuilt a HAP.
