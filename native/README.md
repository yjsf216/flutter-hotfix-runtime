# Bundled patch-store IO

`patch_store_io.c` implements the shared POSIX file boundary for Android, iOS
and OHOS. Compile it into the app/engine; never distribute this library as a
hot-update artifact. Dart uses its C ABI through `NativeStoreIo`.

The trusted app supplies a canonical absolute app-private root. Every path
component is traversed with `openat` and `O_NOFOLLOW`. Reads pin a regular,
single-link inode and return a bounded owned buffer. Writes use an exclusive
temporary inode, file `fsync`, `renameat`, then directory `fsync`; newly created
directories also sync their parent. A directory-inode `flock` protects the
entire state read/modify/write transaction across separate owners. Each owner
opens its own root descriptor and closes it at shutdown.

```sh
ANDROID_NDK_HOME="$PWD/work/upstream/dart-sdk/third_party/android_tools/ndk" \
OHOS_NATIVE_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native \
  sh native/run_patch_store_io_check.sh
```

The host check uses ASan/UBSan, competing processes, reader/writer races,
symlinks/hardlinks/FIFOs, a killed lock owner and a limited-file-size write
failure. With the indicated installed SDKs, the same command compiles and links
arm64 Android/OHOS shared libraries and an iOS dynamic library. It never runs a
device or emulator. Cross-linking does not establish device behavior or actual
power-loss recovery; those remain platform verification gates.

`run_compiled_dbc3.sh` additionally runs the P-256 authenticated DBC3 pipeline
through this native store and tests concurrent Dart-isolate transactions. Its
temporary dylib path is a host-only test input; production resolves the bundled
symbols with `HOTFIX_NATIVE_STORE=true`. Android/OHOS open the fixed bundled
`libpatch_store_io.so`; iOS uses `DynamicLibrary.process()` and the signed
application's statically linked archive. No library name comes from a patch.

## Platform packaging

`CMakeLists.txt` is shared by all three platforms. The Android spike's Gradle
`externalNativeBuild` packages the library directly into the APK. Apple consumers
link the CMake `patch_store_io` target, whose transitive `-u` flags retain every
FFI symbol even with dead stripping. Consumers linking the archive manually must
preserve those flags. OHOS uses the SDK's existing CMake toolchain; adding the
resulting library to the Flutter HAR is still pending.

After building the Android APK described in the repository README, run:

```sh
ANDROID_APK="$PWD/spikes/android_spike/build/app/outputs/flutter-apk/app-release.apk" \
ANDROID_NDK_HOME=/path/to/android-sdk/ndk/28.2.13676358 \
OHOS_NATIVE_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native \
  sh native/run_packaging_check.sh
```

This checks actual APK ELF exports and 16 KiB segment alignment, cross-links an
iOS arm64 executable with no C references to the FFI symbols, and builds/inspects
the OHOS shared library. A host executable verifies name-based symbol lookup.
Only that host executable is run. This does **not** establish that a Flutter
Engine can load DBC3, that the full iOS/HAR app is packaged, or that any target
platform executes a patch.
