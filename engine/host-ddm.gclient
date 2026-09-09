# Copy to an isolated Flutter 3.41.9 checkout after preparing its pinned Dart
# source and dependencies. This first build supplies host Engine verification;
# Android/iOS/OHOS release packaging remains a separate target-specific gate.
solutions = [{
    "name": ".",
    "url": "https://github.com/flutter/flutter.git",
    "managed": False,
    "deps_file": "DEPS",
    "custom_vars": {
        "download_android_deps": False,
        "download_jdk": False,
        "download_dart_sdk": False,
        "download_esbuild": False,
        "download_emsdk": False,
        "download_fuchsia_deps": False,
        "download_fuchsia_sdk": False,
        "run_fuchsia_emu": False,
        "setup_githooks": False,
        "use_rbe": False,
    },
    # These already exist as isolated copies from the identical c70f78e Dart
    # checkout. No gclient operation may update the original compiler workspace.
    "custom_deps": {
        # GN's release flutter_engine dependency graph does not use SwiftShader;
        # it belongs to the excluded host tester/examples, not this AOT gate.
        "engine/src/flutter/third_party/swiftshader": None,
        "engine/src/flutter/third_party/dart": None,
        "engine/src/flutter/third_party/dart/third_party/binaryen/src": None,
        "engine/src/flutter/third_party/dart/third_party/devtools": None,
        "engine/src/flutter/third_party/dart/third_party/perfetto/src": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/ai": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/core": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/dart_style": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/dartdoc": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/ecosystem": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/http": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/i18n": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/leak_tracker": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/native": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/protobuf": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/pub": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/shelf": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/sync_http": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/tar": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/test": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/tools": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/vector_math": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/web": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/webdev": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/webdriver": None,
        "engine/src/flutter/third_party/dart/third_party/pkg/webkit_inspection_protocol": None,
        "engine/src/flutter/third_party/dart/tools/sdks/dart-sdk": None,
        # A host build does not need Linux cross tools. Keep the pinned macOS
        # Engine Clang; the standalone Dart build uses a DIFFERENT revision.
        "engine/src/flutter/buildtools/linux-x64/clang": None,
        "engine/src/flutter/buildtools/mac-x64/clang": None,
    },
}]
