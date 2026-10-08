# Android 手动接入与排错参考

日常使用先看[简化流程](GETTING_STARTED.md)。本文用于复杂工程的手动适配，以及工具链、原生接入和低层命令排错。

目标：安装 Git 版本 A，正常修改 Dart 代码并提交 B，再通过补丁让已安装 A 的测试手机得到修复，不重新安装 B 的 APK。

本教程使用 macOS 开发机、Android arm64 测试手机和本机补丁服务，不绑定业务项目。
应用接入和命令流程基于现有实现；以下通用 Gradle、入口代码是适配模板，不是对所有 Flutter 工程重新执行过的验收证明。
生产部署、iOS 接入不在本教程范围内。

**必须先知道：仓库不附带已编译的定制 Engine，也没有从空机器自动安装全部工具链的命令。**
第 1 步没有通过前，不要继续构建 App。普通 Flutter Engine 不能代替 DDM Engine。
普通已发布 App 如果没有预先接入运行时，也不能直接接收本教程的补丁。

## 1 准备并检查工具链

准备两个同级目录，应用必须是独立 Git 仓库根目录，不能直接把仓库内的 `examples/order_app` 当成 Git 构建根目录：

```text
workspace/
  flutter-hotfix-runtime/   工具仓库，包含准备好的 work/upstream 工具链
  hotfix_demo/              你的测试 Flutter App，具有自己的 .git 目录
```

下面的 YAML 依赖和 CMake 片段按这个同级布局编写。目录布局变化时要同步调整这些路径；
Shell 环境变量不会自动替换 YAML、Gradle 或 JSON 中的字符串。

固定工具链要求：

| 项目 | 要求 |
| --- | --- |
| Flutter | 3.41.9，框架提交 `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694` |
| Engine 提交 | `42d3d75a56efe1a2e9902f52dc8006099c45d937`，Android arm64 Release，启用 `dart_dynamic_modules` |
| Dart 源码 | `c70f78e7d682c158c15ca0c26c729b3ccb932284`，包含已解析依赖及 `.dart_tool/package_config.json` |
| 其他工具 | Git、Python 3、OpenSSL、适配工程的 JDK/Android SDK、NDK 和 CMake |

定制 Engine 的依赖、补丁和构建命令见[工具链构建说明](engine/README.md#android-arm64-cross-build-preflight)。
先完成该说明中的源码/依赖准备，再运行相应 GN 和 Ninja 构建；只有 dry-run 成功不够。
当前 CLI 还依赖固定目录布局，不要只修改环境变量而忽略 `spikes/patch_ir_spike/pubspec.yaml` 中的本地依赖路径。

把以下环境配置保存到仓库之外的 `/absolute/private/hotfix-demo-env.sh`。
下列 `/absolute/...` 都要替换成自己的真实绝对路径：

```sh
export HOTFIX_ROOT=/absolute/workspace/flutter-hotfix-runtime
export APP_ROOT=/absolute/workspace/hotfix_demo
export FLUTTER_SDK=/absolute/path/to/flutter-3.41.9
export DART_BIN="$FLUTTER_SDK/bin/cache/dart-sdk/bin/dart"
export DART_SDK_SOURCE="$HOTFIX_ROOT/work/upstream/dart-sdk"
export GEN_SNAPSHOT="$HOTFIX_ROOT/work/upstream/flutter-engine-ddm/engine/src/out/hotfix_android_release_arm64/artifacts_arm64/gen_snapshot_arm64"
export ANDROID_SDK_ROOT=/absolute/path/to/android-sdk
export ANDROID_BUILD_TOOLS="$ANDROID_SDK_ROOT/build-tools/35.0.0"
export JAVA_HOME=/absolute/path/to/jdk-17/Contents/Home
export ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
export DEVICE_SERIAL=YOUR_TEST_DEVICE_SERIAL
export APP_ID=com.example.hotfix_demo
export KEY_DIR=/absolute/private/hotfix-demo-keys
export SERVICE_DIR=/absolute/private/hotfix-demo-service
export ORIGIN=http://127.0.0.1:18091
export HOTFIX_PUBLIC_KEY_FILE="$KEY_DIR/public-key.txt"
export TOKEN_FILE="$SERVICE_DIR/publish-token.txt"
```

这里的 build-tools、JDK 路径要指向已安装且适配工程的版本；`KEY_DIR`、`SERVICE_DIR` 应放在源码仓库之外。
在终端 1 加载它，后续终端也加载同一个文件。这个文件只保存路径，不保存私钥或令牌内容：

```sh
source /absolute/private/hotfix-demo-env.sh
```

执行检查：

```sh
"$FLUTTER_SDK/bin/flutter" --version
"$DART_BIN" --version
python3 --version
openssl version
"$JAVA_HOME/bin/java" -version
git -C "$DART_SDK_SOURCE" rev-parse HEAD
test -f "$DART_SDK_SOURCE/.dart_tool/package_config.json"
test -x "$GEN_SNAPSHOT"
test -f "$(dirname "$GEN_SNAPSHOT")/../lib.stripped/libflutter.so"
test -x "$ANDROID_BUILD_TOOLS/aapt"
test -x "$ANDROID_BUILD_TOOLS/apksigner"
"$ADB" -s "$DEVICE_SERIAL" get-state
```

**成功标志：** 固定版本匹配，文件检查全部退出 0，指定手机返回 `device`。
缺少 Engine、源码依赖、SDK 或设备授权时先处理缺项；不要用系统 `dart` 或 stock `libflutter.so` 替代。
本教程不替你操作未明确选定的设备。

## 2 准备测试 App 和 Dart 依赖

已有 App：先确认普通 Release 构建及启动正常，在独立测试分支接入，不直接修改线上发布分支。
新建 App：仅在 `APP_ROOT` 尚不存在时执行下面整段，创建并提交初始工程；已有 App 跳过：

```sh
test ! -e "$APP_ROOT" &&
  "$FLUTTER_SDK/bin/flutter" create --platforms=android --org com.example "$APP_ROOT" &&
  git init "$APP_ROOT" &&
  git -C "$APP_ROOT" add . &&
  git -C "$APP_ROOT" commit -m "初始化 Flutter 测试工程"
```

先确认 Git 的作者信息已配置。上述 `git add .` 只适用于刚生成、没有密钥的测试工程，不用于已有业务仓库。
本文假定默认 Kotlin `MainActivity`、默认 Gradle 输出目录和一个无参数的 Dart `main()`。
使用预热/缓存 FlutterEngine、自定义启动器或已有 CMake 工程时，需要按实际宿主适配，不能直接覆盖文件。

在 App 的 `pubspec.yaml` 合并以下内容，不要删除已有依赖：

```yaml
dependencies:
  patch_ir_spike:
    path: ../flutter-hotfix-runtime/spikes/patch_ir_spike

dependency_overrides:
  _fe_analyzer_shared:
    path: ../flutter-hotfix-runtime/work/upstream/dart-sdk/pkg/_fe_analyzer_shared
```

解析依赖并检查工具入口：

```sh
cd "$HOTFIX_ROOT/spikes/patch_ir_spike"
"$DART_BIN" pub get
cd "$APP_ROOT"
"$FLUTTER_SDK/bin/flutter" pub get
sh "$HOTFIX_ROOT/tool/hotfix" --help
```

**成功标志：** 两个项目依赖解析成功，帮助中出现 `release-android`、`patch-android`、`publish`。
找不到 `dynamic_modules`、`kernel` 或 `_fe_analyzer_shared` 时，检查第 1 步的源码目录与依赖，不要随意换包版本。

## 3 接入原生宿主和 Dart 启动入口

### 3.1 让 Android 传入三个私有路径

在 App 现有的 `android/app/src/main/kotlin/.../MainActivity.kt` 类中合并这个方法，保留原包名、父类和插件注册逻辑：

```kotlin
override fun getDartEntrypointArgs(): List<String> {
    val root = java.io.File(filesDir.canonicalFile, "hotfix")
    return listOf(
        java.io.File(root, "inbox/patch.bytecode").path,
        java.io.File(root, "inbox/manifest.json").path,
        java.io.File(root, "store").path,
    )
}
```

顺序是字节码、清单、存储根目录。在线发布不用手工创建或向手机推送 inbox 文件；
运行时会在存储根目录下按基线 ID 隔离版本状态。
缓存 Engine 可能不经过此方法，必须确认参数在执行 Dart 入口前实际传入。

### 3.2 打包原生存储库并指定 flavor

统一打包入口目前要求显式的 Android flavor。已有 flavor 就使用它；没有时可添加测试用 `hotfix`。
包名保持 `APP_ID` 的实际值，测试示例不要额外添加 `applicationIdSuffix`，否则配置也必须对应完整包名。
以下片段合并到现有 `android { ... }` 中，**按项目使用的 DSL 二选一**。

Kotlin DSL，`android/app/build.gradle.kts`：

```kotlin
android {
    ndkVersion = "28.2.13676358"
    flavorDimensions += "distribution"
    productFlavors {
        create("hotfix") {
            dimension = "distribution"
            ndk { abiFilters += "arm64-v8a" }
        }
    }
    if (project.hasProperty("hotfixRuntime")) {
        externalNativeBuild {
            cmake {
                path = file("../../../flutter-hotfix-runtime/native/CMakeLists.txt")
                version = "3.22.1"
            }
        }
    }
}
```

Groovy，`android/app/build.gradle`：

```groovy
android {
    ndkVersion '28.2.13676358'
    flavorDimensions 'distribution'
    productFlavors {
        hotfix {
            dimension 'distribution'
            ndk { abiFilters 'arm64-v8a' }
        }
    }
    if (project.hasProperty('hotfixRuntime')) {
        externalNativeBuild {
            cmake {
                path file('../../../flutter-hotfix-runtime/native/CMakeLists.txt')
                version '3.22.1'
            }
        }
    }
}
```

已有 flavor dimension、CMake 构建或 NDK 要求的项目需要合并适配，不能重复定义另一套冲突配置。
确认 NDK/CMake 已安装，且 `release` 签名配置可用。全新测试 App 可使用其测试签名；
覆盖已有安装包必须保持同一 APK 签名，正式分发不能依赖临时调试密钥。

### 3.3 新增定制 Dart 入口

创建 App 的 `lib/main_hotfix.dart`，原有 `lib/main.dart` 保持正常业务入口：

```dart
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:patch_ir_spike/dbc3_dispatch.dart';
import 'main.dart' as app;

Future<void> main(List<String> args) async {
  if (!Platform.isAndroid || args.length != 3) {
    throw StateError('Android hotfix host must provide three private paths');
  }
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final patch = await bootSignedModule(args);
  await Future<void>.sync(app.main);
  await binding.waitUntilFirstFrameRasterized;
  if (patch != null && !commitModuleHealth(patch)) {
    throw StateError('Hotfix health commit failed');
  }
  await checkUpdatesAfterHealth(patch);
}
```

示例假定原有 `app.main` 无参数，返回 `void` 或 `Future<void>`；实际签名不同时按真实入口适配。
首帧只是最小健康检查点。实际 App 应在确认必要初始化和关键界面正常后才提交健康，
不能在 `finally`、异常处理页或仅下载成功时调用 `commitModuleHealth`。
已有首帧延迟或错误捕获机制的项目需要一起核对。

`probe.dart` 不是必需文件，本教程不依赖它。不要用普通 `flutter run -t lib/main_hotfix.dart`
证明热更新能力；只有匹配的定制 Engine、AOT 和宿主参数组合才是此处的运行环境。

**成功标志：** 接入代码静态检查通过，原启动逻辑没有被替换，后续构建的 APK 包含 `libpatch_store_io.so`。

## 4 配置本地网络与基线信息

在 App 主 `AndroidManifest.xml` 的 `<manifest>` 下确认有：

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

本机测试地址使用 HTTP，还需要 Android 网络策略允许 loopback。只在测试 flavor 合并
`android/app/src/hotfix/AndroidManifest.xml`：

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:networkSecurityConfig="@xml/hotfix_network_security" />
</manifest>
```

创建 `android/app/src/hotfix/res/xml/hotfix_network_security.xml`：

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="false" />
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
    </domain-config>
</network-security-config>
```

若工程已有网络安全配置，合并测试规则，不要直接覆盖原策略。正式 HTTPS flavor 不应带此测试例外。

在 App 根目录创建 `hotfix.android.json`，确保版本与 `pubspec.yaml`、包名与 Gradle 实际配置一致：

```json
{
  "project": ".",
  "entry": "lib/main_hotfix.dart",
  "patchScope": "lib",
  "platform": "android",
  "appId": "com.example.hotfix_demo",
  "release": "1.0.0+1",
  "androidFlavor": "hotfix",
  "dartDefines": {},
  "updateOrigin": "http://127.0.0.1:18091",
  "allowDevelopmentHttp": true
}
```

业务依赖 `--dart-define` 时填入 `dartDefines`，不要依赖另一份命令行中未归档的值。
这些配置会绑定基线；不能在 B 阶段改地址或编译参数来更新已安装 A。

为第一次演练选定一个现有可见页面，在其已存在的 `build` 方法中显示文字 `版本 A`。
务必在构建 A **之前**完成；未编译到基线的新页面不能事后加入补丁。

## 5 生成补丁签名密钥并提交 A

补丁签名密钥与 APK 的 Android 签名密钥是两回事。生成一套仅供本次测试的补丁密钥：

```sh
umask 077
test ! -e "$KEY_DIR" && "$DART_BIN" \
  "$HOTFIX_ROOT/spikes/patch_ir_spike/tool/signature_check.dart" keygen "$KEY_DIR"
export HOTFIX_PUBLIC_KEY_FILE="$KEY_DIR/public-key.txt"
test -f "$KEY_DIR/private.pem"
test -f "$HOTFIX_PUBLIC_KEY_FILE"
```

已存在的密钥目录不要重复生成覆盖。已有基线必须继续使用其对应私钥；丢失私钥不能用新密钥冒充。
公钥进入 App，私钥留在签名机；发布服务只需要公钥。

确保 App 的 `.gitignore` 排除 `build/`、`.dart_tool/`、本地 SDK 配置、签名文件和令牌。
保留依赖锁文件以便复现；若项目忽略 `pubspec.lock`，需明确调整自己的应用仓库策略。
执行必要的业务测试和静态检查，然后审查并提交接入改动：

```sh
cd "$APP_ROOT"
"$FLUTTER_SDK/bin/flutter" test
"$FLUTTER_SDK/bin/flutter" analyze
git status --short
```

用 `git add` 选择本次接入、配置、依赖和页面文案文件，核对暂存区没有私钥和构建产物，再提交：

```sh
git diff --cached --stat
git diff --cached --check
git commit -m "接入热更新并建立版本 A"
git status --porcelain
git rev-parse HEAD
```

**成功标志：** `git status --porcelain` 无输出，记下 A 的提交号。
未跟踪文件也会阻止构建；不要用删除无关文件或强制重置来解决，应先分类提交或正确忽略。

## 6 一次构建 APK 与基线归档

回到终端 1，设置本次产物目录，不要提前创建输出目录：

```sh
export BASE_OUT="$APP_ROOT/build/hotfix/release-A"
export PATCH_OUT="$APP_ROOT/build/hotfix/patch-B"
cd "$HOTFIX_ROOT"
sh tool/hotfix release-android "$APP_ROOT/hotfix.android.json" "$BASE_OUT"
```

不要在构建过程中修改源码、依赖、工具仓库或并发运行另一份 App 构建。

**成功标志：** 退出 0，并打印 `PASS: Android archive verified`。归档包含：

| 文件 | 用途 |
| --- | --- |
| `app.apk` | 真正用于本次安装和分发的热更新包 |
| `native.apk` | 中间普通构建包，不是本次热更新分发目标 |
| `android-release.json` | 最后写入的完成标志，记录 Git、基线、APK、库摘要和证书 |
| `baseline/` | 后续生成补丁必须保留的冻结编译输入、配方、元数据和 AOT |

保存**整个归档**以及对应工具版本、依赖和源代码环境，不要只留 APK。
归档含本机路径，当前不保证换任意目录或机器即可直接复现。
不要从常规 Gradle 输出目录随意挑一个 APK，也不要手工替换归档中的库或元数据。

若仅最后打包失败，且 `baseline/project.json` 已记录 Git 提交、AOT 已完成，可在仍处于同一个干净 A 时重试：

```sh
sh tool/hotfix release-android "$APP_ROOT/hotfix.android.json" "$BASE_OUT" --resume-packaging
```

未完成基线则换全新输出目录重建。完成的归档不能覆盖，不能删掉完成标志强行重试。

## 7 启动补丁服务并安装 A

在终端 1 生成服务端和发布端共用的临时令牌文件，放在仓库之外：

```sh
export TOKEN_FILE="$SERVICE_DIR/publish-token.txt"
umask 077
mkdir -p "$SERVICE_DIR"
test ! -e "$TOKEN_FILE" && openssl rand -hex -out "$TOKEN_FILE" 24
export HOTFIX_PUBLISH_TOKEN="$(cat "$TOKEN_FILE")"
export HOTFIX_ALLOW_DEV_HTTP=true
```

不要把令牌打印、提交或嵌入 App。不要覆盖运行中服务使用的令牌文件。

打开终端 2，加载相同路径环境并从文件读取令牌，保持这个进程运行：

```sh
source /absolute/private/hotfix-demo-env.sh
export HOTFIX_PUBLISH_TOKEN="$(cat "$TOKEN_FILE")"
export HOTFIX_PORT=18091
export HOTFIX_BIND=127.0.0.1
sh "$HOTFIX_ROOT/tool/hotfix" serve "$SERVICE_DIR/storage" "$HOTFIX_PUBLIC_KEY_FILE"
```

**成功标志：** 输出 `Delivery service listening on 127.0.0.1:18091`。
浏览器打开根地址没有管理页面是正常的。不要让两个服务进程共享一个存储目录。

在终端 1 安装 A 并建立转发：

```sh
"$ADB" -s "$DEVICE_SERIAL" get-state
"$ADB" -s "$DEVICE_SERIAL" install -r "$BASE_OUT/app.apk"
"$ADB" -s "$DEVICE_SERIAL" reverse tcp:18091 tcp:18091
```

覆盖安装前核对包名、证书和版本；遇到签名不一致或版本降级错误，应停止，不能靠卸载、清数据或伪造版本号绕过。
第一次安装到独立测试 App 不涉及线上用户。

在手机点击 App，确认页面显示 `版本 A`。启动完成后查看服务报告：

```sh
tail -n 10 "$SERVICE_DIR/storage/reports.jsonl"
```

**成功标志：** 页面正常，出现该基线的 `baseline_healthy`。尚未发布补丁时不应有 `downloaded`。
`patch_healthy` 只代表配置的启动健康检查通过，不代替后续业务页面验收。

## 8 正常开发并提交 B

只修改刚才已有页面 `build` 中的文字：`版本 A` 改为 `版本 B 补丁`，作为最小可见修复。
也可以修复兼容范围内的实际业务函数。不要重新安装 APK。

本次补丁中不要改 `pubspec.yaml` 版本、锁文件、原生代码、资源、入口配置或工具版本；
补丁仍绑定 A 的 App 版本，靠独立补丁 ID 标识修复。
补丁 ID、App 版本和基线 ID 是三个不同概念。

假设改动位于 `lib/main.dart`，按实际改动文件调整 `git add`：

```sh
cd "$APP_ROOT"
"$FLUTTER_SDK/bin/flutter" test
"$FLUTTER_SDK/bin/flutter" analyze
git diff --stat
git diff --check
git add lib/main.dart
git commit -m "修复页面文案"
git status --porcelain
git rev-parse HEAD
```

**成功标志：** 工作区干净，B 相对 A 只含受支持的现有 Dart 文件改动。
当前工具连混入的文档变更也会拒绝；不要为了通过检查删除基线信息或缩小校验范围。

## 9 生成并检查签名补丁

终端 1 中保持第 1、5、6 步的环境，运行：

```sh
cd "$HOTFIX_ROOT"
sh tool/hotfix patch-android "$BASE_OUT" HEAD "$PATCH_OUT" "$KEY_DIR" demo-fix-1
```

`HEAD` 指应用仓库当前提交，由基线元数据定位应用仓库，不是工具仓库 HEAD。
传入分支名或提交号也必须等于应用当前检出的提交；命令不会自动切分支。

**成功标志：** 退出 0，打印编译成功及 `signed patch ready`，生成：

- `patch.bytecode`：补丁代码，不是 APK。
- `manifest.json`：签名清单，绑定基线、应用身份、字节码摘要和期限。
- `metadata.json`：编译信息。
- `git-provenance.json`：A/B 提交及变更文件，核对其与修复范围一致。

命令没有上传补丁。失败后不能移除 `.git-pending` 标记强行签名；先解决原因，再使用新输出目录。
不支持的改动应改发完整基线版本，而不是绕过拒绝。

## 10 发布到测试服务并验收生效

终端 2 服务持续运行；终端 1 使用与服务一致的发布令牌：

```sh
sh "$HOTFIX_ROOT/tool/hotfix" publish "$ORIGIN" \
  "$PATCH_OUT/manifest.json" "$PATCH_OUT/patch.bytecode"
```

**成功标志：** `Published signed patch for next-start delivery`。这是服务接收成功，不是手机已经生效。

按顺序操作手机：

1. 完全结束测试 App 进程，再启动一次。App 正常启动后检查服务并下载；本次仍显示 `版本 A`。
2. 看到 `downloaded` 后，再完全结束进程并启动。现在应显示 `版本 B 补丁`。
3. 检查有对应补丁 ID 的 `patch_healthy`，并实际操作修复页面，确认功能正常。

测试手机可用下面命令结束进程，再手动点击图标启动；它不是清除数据：

```sh
"$ADB" -s "$DEVICE_SERIAL" shell am force-stop "$APP_ID"
tail -n 10 "$SERVICE_DIR/storage/reports.jsonl"
sh "$HOTFIX_ROOT/tool/hotfix" stats "$ORIGIN"
```

当前实现只在启动健康检查后检查更新；前台一直不重启的 App 不会因为上传成功就立即变更。
整个第 8 至 10 步不运行 `adb install`，否则无法证明旧安装包是通过补丁修复的。
统计是去重后的事件数，不是独立用户数或可信的总体修复成功率。

**首次闭环完成标志：** A 的 APK 只安装一次，B 仅生成并上传补丁；页面变更和 `downloaded → patch_healthy` 同时成立。

## 11 暂停 灰度与撤回

从 `android-release.json` 读取 `baselineId`，将真实值设置为 `BASELINE_ID`，不要填写 App 版本号或补丁 ID。
暂停与恢复新分发：

```sh
sh "$HOTFIX_ROOT/tool/hotfix" pause "$ORIGIN" "$BASELINE_ID" true
sh "$HOTFIX_ROOT/tool/hotfix" pause "$ORIGIN" "$BASELINE_ID" false
```

暂停不撤销已安装补丁，也不能保证撤销已经下载、等待下次启动的补丁。
要禁用某个补丁 ID，签名并发布撤回策略，使用一个新的输出目录：

```sh
export WITHDRAW_OUT="$APP_ROOT/build/hotfix/withdraw-demo-fix-1"
sh "$HOTFIX_ROOT/tool/hotfix" policy "$BASE_OUT/baseline" "$PATCH_OUT" \
  "$KEY_DIR" "$WITHDRAW_OUT" withdraw
sh "$HOTFIX_ROOT/tool/hotfix" publish "$ORIGIN" \
  "$WITHDRAW_OUT/manifest.json" "$WITHDRAW_OUT/patch.bytecode"
```

手机联网检查后收到 `withdrawn`，下次冷启动切换到可用健康版本或内置基线；当前页面不会被强行替换。
撤回对该 ID 永久有效，重新修复需要新补丁 ID。
`policy` 的最后一个参数也可以是 `0..100`，用于签署灰度百分比；必须再执行 `publish` 才会生效。
灰度应从最后发布的策略目录生成下一份策略；小比例分发不能替代内部测试。

补丁接收期限默认 24 小时。过期的新补丁不能接收；当前加载器已确认健康的本地补丁不会仅因到期失效，
但仍需验签和校验文件。连续两次未完成健康检查的启动会使候选补丁被禁用，下一次恢复 LKG 或基线。
不要在真实用户环境故意注入启动故障来验证此机制。

## 12 结束测试及转向正式部署

在终端 2 按 Ctrl+C 停止服务。在终端 1 移除指定设备的转发：

```sh
"$ADB" -s "$DEVICE_SERIAL" reverse --remove tcp:18091
unset HOTFIX_PUBLISH_TOKEN
```

按自己的密钥管理策略保管或销毁临时发布令牌；不要误删仍有基线依赖的签名私钥和归档。
停止服务不会自动移除已安装补丁。需要回到基线时，应先完成第 11 步的撤回并在手机验收。

正式部署前：

- 配置真实 HTTPS origin、关闭开发 HTTP，使用正确的 Android 正式签名和补丁签名边界。
- 配置改变后构建新基线；已安装的 loopback 测试包不会自动改连正式域名。
- 服务端先获得对应公钥、发布鉴权、容量监控与访问/滥用防护，再进行小范围发布。
- 冻结工具、依赖与基线；更换编译器或修改外部 path 依赖不能假设仍兼容旧归档。
- 核对[安全模型](SECURITY.md)和[服务限制](delivery/README.md#checks-and-explicit-limits)。当前开发服务不是生产托管平台。

## 常见失败如何处理

| 现象 | 检查与处理 |
| --- | --- |
| 缺少 kernel、dynamic_modules 或 Engine | 回到第 1、2 步，准备固定源码与定制引擎；不要替换为 stock Engine |
| `requires a clean checkout` | 查看 App 的已修改和未跟踪文件，审查后提交或正确忽略，不强制重置 |
| `New base app required` / 非补丁文件变化 | 核对 A→B 的完整 Git diff；原生、依赖、资源等改动发新基线 |
| 找不到 flavor / Gradle task | 配置必须使用项目已有 flavor；合并第 3 步配置并核对真实 APK 输出结构 |
| Android 安装签名不一致或降级 | 停止覆盖，核对证书和版本；不要卸载用户 App 或清数据绕过 |
| `MissingPluginException` | 检查原生插件注册及生成的 Dart 注册文件；修复接入后重新构建基线 |
| `download_failed` | 检查服务是否运行、设备转发、两端端口、HTTP 开关、Android 网络策略和网络连接 |
| `rejected` | 核对基线、公钥、版本身份、摘要、期限，以及补丁是否已失败或撤回 |
| `not_selected` | 当前安装不在灰度范围；0% 不分发，降低百分比不等于撤回 |
| `downloaded` 但界面未变 | 尚未冷启动，或修改代码路径尚未执行；不能用覆盖安装 B 代替排查 |
| `patch_healthy` 但业务仍错 | 健康检查覆盖不足；检查实际修改范围、执行路径和业务断言 |
| 服务返回 401 / 409 / 507 | 分别检查发布令牌、同 ID 内容/策略冲突、报告日志或撤回 feed 容量 |

代码位置和所有配置字段见[接入与发布参考](GIT_WORKFLOW.md)，API 见[补丁服务说明](delivery/README.md)。
本教程的命令与入口已按源码核对；通用模板仍需在自己的测试工程构建和验收，不应直接用于线上发布。
