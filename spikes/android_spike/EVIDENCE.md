# Host evidence — 2026-09-04

Toolchain: Flutter 3.41.9, Dart 3.11.5, Engine `42d3d75a56`. Target: `android-arm64`. Tests and `flutter analyze` passed.

| Build | APK SHA-256 | `libapp.so` SHA-256 |
|---|---|---|
| `BASELINE` | `eb97fab7bd35eb23be95a50fcc4e2a91303e599be2de5e7807d966a4ca6ab1eb` | `2ea5b813024a714cb5d3c3f389f851e7c8874562c82e4a0c10e2ffa4a51ce072` |
| `PATCHED` | `861d3fa9c80a614660958f77bb7356867d15bca4d45998681c39c249f76c9963` | `15183de4d9eaaa1da35886b8f933740f119199486f4884d8dbbc04ce2cefc763` |

The two builds used the same command and differed only in the Dart marker literal. Extracted binaries live under ignored `work/android-spike/`; they are research artifacts, not committed release inputs. No device result is claimed.
