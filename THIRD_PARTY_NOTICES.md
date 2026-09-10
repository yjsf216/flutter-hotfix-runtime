# Third-party notices

Apache-2.0 applies to original project contributions, not to a relicensing of
third-party material. Preserve existing upstream notices when redistributing.

## Material included in this source repository

Flutter-generated Android project templates/resources and Flutter build patch
context originate from the Flutter project. These remain BSD-3-Clause licensed:
see [the retained license](LICENSES/Flutter-BSD-3-Clause.txt). Project changes
add the native store, prebuilt packaging, network permissions and runtime hooks;
the patch files themselves identify the modified upstream build lines.

## External build/runtime dependencies (not vendored here)

| Dependency | Upstream license / distribution |
|---|---|
| Flutter and Dart SDK/compiler packages | BSD-3-Clause for project code; bundled third parties retain their own licenses |
| Dart `crypto` and `http` | BSD-3-Clause |
| PointyCastle | MIT |
| Ruby `xcodeproj` | MIT |
| libimobiledevice | LGPL-2.1-or-later library; its upstream tools have their own licensing |
| Android/Xcode SDKs and toolchains | Their respective vendor terms; not redistributed here |

The ignored `work/` directory is where developers obtain SDK source, toolchains,
build outputs and private test artifacts. It is not part of this source release.
No Flutter/Dart Engine binary, Apple SDK, private signing key, provisioning profile
or device data is distributed in this repository.

If you redistribute a built application or Engine, collect and ship the notices
required by its actual bundled dependencies. This dependency overview is not a
complete binary-distribution license inventory and does not replace upstream
license files. Do not assume this project's Apache-2.0 covers those binaries.
