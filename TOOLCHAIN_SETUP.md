# 工具链准备与自动检查

先运行只读检查器：

```sh
sh /path/to/flutter-hotfix-runtime/tool/hotfix doctor --guide
```

它一次汇总缺失组件、固定版本和 Android DDM 配置，失败返回退出码 1。
`doctor --json` 提供机器可读结果。在已初始化的 App 目录运行，会读取该 App 保存的路径。

当前完整验收宿主为 **macOS Apple Silicon**，目标为 **Android arm64**。
使用后台无需 Node、数据库或 Jenkins。定制 Engine 尚无项目提供的预编译下载包，需源码构建。

## 1. 基础工具与 Flutter

准备 Python 3.10+、Git、OpenSSL、JDK 17，以及构建 Engine 所需的 Xcode/命令行开发工具。
为本项目保留独立的固定 Flutter 安装：

```sh
git clone --branch 3.41.9 https://github.com/flutter/flutter.git flutter-3.41.9
./flutter-3.41.9/bin/flutter --version
./flutter-3.41.9/bin/flutter precache --android
```

固定 Flutter 提交为 `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694`，
`bin/internal/engine.version` 必须是 `42d3d75a56efe1a2e9902f52dc8006099c45d937`。
检查器会拒绝版本不匹配，不会切换或升级其他项目的 FVM SDK。

## 2. Android SDK 与 JDK

通过 Android Studio SDK Manager 或已安装的 sdkmanager 准备组件：

```sh
/path/to/android-sdk/cmdline-tools/latest/bin/sdkmanager \
  'platform-tools' 'platforms;android-36' 'build-tools;36.1.0' \
  'ndk;28.2.13676358' 'cmake;3.22.1'
```

Android SDK 许可需自行阅读并接受。首次下载需要网络，不属于只读 doctor 的行为。
build-tools 36.1.0 是 Engine 准备记录所用版本，APK 检查也已验证 build-tools 37。
工具自动选择已安装的最新可用版本，或使用 `ANDROID_BUILD_TOOLS` 指定目录。
其他 JDK/SDK 组合需自行验证 App 的 Gradle/AGP 兼容性。

## 3. 固定 Dart 源码与定制 Engine

按 [Engine 源码准备记录](engine/README.md)准备独立源码树及固定依赖：

| 输入 | 要求 |
|---|---|
| Dart 源码 | `c70f78e7d682c158c15ca0c26c729b3ccb932284` |
| Dart 编译依赖 | 已同步 third_party 并生成 `.dart_tool/package_config.json` |
| Engine Clang | `8c7a2ce01a77c96028fe2c8566f65c45ad9408d3` |
| Engine 补丁 | `engine/patches/host_clang_plist.patch`、`android_host_clang.patch` |
| 构建配置 | Android、arm64、release、`dart_dynamic_modules=true` |

Dart 上游依赖准备完成后，可在 Dart 源码根目录运行 `python3 tools/generate_package_config.py`。
它需要源码树自己的 bootstrap SDK，会解析依赖，不是纯文件复制操作。

`engine/host-ddm.gclient` 是历史复用配置，跳过了当时已准备的 Dart 和 Android 依赖，
不能直接作为空机器安装器。首次准备需按固定上游 DEPS 完成这些输入。
本项目目前没有完整自动化的源码同步/CIPD 安装器；详细版本及已验证步骤保留在 Engine 文档中。
普通 Flutter Engine 不能替代 DDM Engine。

源码、依赖、补丁齐备后，在独立 Flutter checkout 的 engine/src 执行实际编译：

```sh
python3 flutter/tools/gn --android --android-cpu=arm64 --runtime-mode=release \
  --no-lto --no-prebuilt-dart-sdk --no-full-dart-sdk --no-build-engine-artifacts \
  --dart-dynamic-modules --allow-deprecated-api-calls \
  --target-dir=hotfix_android_release_arm64 --gn-args=enable_unittests=false

../../third_party/ninja/ninja -j2 -C out/hotfix_android_release_arm64 \
  flutter/shell/platform/android:flutter_shell_native \
  flutter/lib/snapshot:create_macos_gen_snapshot_arm64_arm64
```

Ninja 的 -n 只是 dry-run，不能作为编译成功证据。该固定版本的 `--no-enable-unittests`
会关闭 DDM，应使用上述 GN 参数。最终同一输出目录必须包含：

- artifacts_arm64/gen_snapshot_arm64：在 Mac 上执行的 Android 快照生成器。
- lib.stripped/libflutter.so：Android arm64 DDM Engine。
- args.gn：固定 Dart 版本及有效 DDM 配置。

## 4. 显式配置一次，后续复用

替换以下路径为自己的安装位置：

```sh
export FLUTTER_SDK=/path/to/flutter-3.41.9
export ANDROID_SDK_ROOT=/path/to/android-sdk
export JAVA_HOME=/path/to/jdk-17/Contents/Home
export DART_SDK_SOURCE=/path/to/prepared/dart-sdk
export GEN_SNAPSHOT=/path/to/engine/src/out/hotfix_android_release_arm64/artifacts_arm64/gen_snapshot_arm64

sh /path/to/flutter-hotfix-runtime/tool/hotfix doctor --guide
```

也可把 --flutter-sdk、--android-sdk、--java-home、--dart-sdk-source、--gen-snapshot
传给 doctor 或 init。优先级：显式参数、App 保存配置、环境变量、自动发现/默认路径。

检查通过后按[五步使用流程](GETTING_STARTED.md)初始化 App。init 会保存路径到 App 的
`.hotfix/local.json`，并在 Runtime 自己的忽略目录 work/upstream/dart-sdk 建立指向显式
Dart 源码的链接，以满足运行时包的固定相对依赖。它不复制整套 SDK、不修改上游源码，
不覆盖已有其他目录或链接；冲突时使用独立 Runtime clone。doctor 和 init --dry-run 不会创建链接。

## 工具版本与基线

升级工具后，应为新发行版构建新基线。修复历史版本需使用匹配的工具版本和归档，
不要手工改工具指纹绕过检查。备份 App 的 .hotfix、后台专用副本归档和签名密钥；只备份 Git 不够。
