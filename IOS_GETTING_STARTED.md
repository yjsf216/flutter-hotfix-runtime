# iOS：统一命令与管理后台

> 通用 `init` 仍使用旧运行时接入；已迁移到独立 `patch_runtime` 的 App 不要重复运行。
> 拆分状态与维护入口见 [PROJECT_LAYOUT.md](PROJECT_LAYOUT.md)。

iOS 使用与 Android 相同的五步流程：初始化、构建基础版本、正常修改并提交 Dart、
生成补丁、验收后发布。无需 Jenkins。此入口目前为 macOS 上的单人开发测试版，
**不是 App Store 分发方案**；Apple 开发签名和设备授权仍不可省略。

## 1. 准备与初始化

固定 Flutter 3.41.9、Dart 源码及 iOS arm64 Release DDM Engine。
`gen_snapshot_arm64` 与 `Flutter.framework` 必须来自同一个 iOS Engine 输出，
不是 Android 输出。Engine 构建见 [说明](engine/README.md)和 `engine/build_ios_ddm.sh`。
需要完整 Xcode、可用 Apple 开发账号、Ruby `xcodeproj` gem。

```sh
sh /path/to/flutter-hotfix-runtime/tool/hotfix doctor --platform ios --guide \
  --flutter-sdk /path/to/flutter-3.41.9 \
  --dart-sdk-source /path/to/dart-sdk-source \
  --gen-snapshot /path/to/hotfix_ios_release_arm64/artifacts_arm64/gen_snapshot_arm64
```

进入 Flutter App 的独立 Git 根目录：

```sh
sh /path/to/flutter-hotfix-runtime/tool/hotfix init --platform ios \
  --ios-team YOURTEAMID \
  --flutter-sdk /path/to/flutter-3.41.9 \
  --dart-sdk-source /path/to/dart-sdk-source \
  --gen-snapshot /path/to/hotfix_ios_release_arm64/artifacts_arm64/gen_snapshot_arm64 \
  --dev-lan --origin http://192.168.1.100:18091
```

先预览可加 `--dry-run`。真实运行会备份旧文件、添加 runtime 依赖、生成
`hotfix.ios.json` 和 `lib/main_hotfix.dart`、接入原生安全存储和显式 Engine 启动，
保留插件注册、资源与原有安装包包名。审查、测试并提交这些接入改动。

自动接入仅接受固定 Flutter 的标准 Swift Runner/AppDelegate 模板。
自定义 delegate、scene 生命周期或签名方式需人工适配，工具不会直接覆盖。
当前标准接入使用单窗口 SceneDelegate：AppDelegate 启动唯一的显式 Engine，
SceneDelegate 绑定窗口与 FlutterViewController 并保留 Flutter scene 生命周期转发。
后续 iOS 版本及自定义多窗口应用仍需单独验证。

### 已有自定义 App 或已有 Android 接入

不要反复运行自动接入来覆盖业务 delegate。在 iOS 测试分支中人工合并：

1. 保留已有 runtime 依赖和入口；入口须支持 `Platform.isIOS` 及三个私有路径参数。
2. 将 `native/patch_store_io.c` 加入 Runner 的 Sources，保留其头文件位置；
   Swift bridging header 声明 `int psio_set_app_base(const char *path);`。
3. 启动 Engine 前以 OS 提供的 Documents 路径执行 `realpath`，调用
   `psio_set_app_base`；以显式 `FlutterEngine.run` 传入 inbox bytecode、manifest、
   store 三个路径。沿用业务插件注册与窗口/scene 生命周期，不能让另一个隐式
   Engine 抢先运行普通 Dart 入口。标准实现见 `tool/ios_integration.py` 的 `DELEGATE`。
4. 保留 native 的八个 `psio_*` 符号，设置 Release arm64 和匹配的签名 Team。
   链接参数见 `tool/ios_integrate.rb`；脚本会复用已有源文件引用，避免重复加入编译阶段。
5. 添加配置并提交，再运行上面的 iOS init，它会复用已存在的配置，不改源码：

   ```json
   {
     "project": ".", "entry": "lib/main_hotfix.dart", "patchScope": "lib",
     "platform": "ios", "dartDefines": {},
     "updateOrigin": "https://updates.example.com", "allowDevelopmentHttp": false
   }
   ```

配置文件名为 `hotfix.ios.json`。局域网测试按上述精确网络例外合并 Info.plist，
并显式设置 `allowDevelopmentHttp` / `allowDevelopmentLan`；不要全局关闭 ATS。
自定义项目仍须完成首帧、实际业务、插件以及冷启动真机验收；标准示例通过不代表
任意 delegate 或插件组合都已验证。

同一工程可保留 Android 的 `.hotfix/run`，新增的 iOS 配置、状态和令牌保存在
`.hotfix/ios/`，入口为 `.hotfix/ios/run`。各平台使用独立后台端口和构建副本，
不会切换或覆盖另一个平台的副本。早期直接保存在 `.hotfix/local.json` 的 iOS
工程仍兼容原 `.hotfix/run`，不会自动迁移已有归档。

默认从 Xcode Release 的有效构建设置读取包名、签名团队、最低版本和唯一 Scheme。
首次接入也优先读取已有团队；尚未配置时先在 Xcode 选择，或使用 `--ios-team`。
多个 Scheme 时需显式指定 `native.scheme`，不会猜测。结果冻结到基础包归档的 `resolved-config.json`。

已接入且启用 `HotfixRuntimeEnabled` 的 `Runner/Info-Hotfix.plist` 会自动识别。
其他路径可通过 `native.infoPlist` 显式指定（旧 `iosInfoPlist` 仍可读取）：用于保留普通构建的 storyboard/生命周期设置，
只为热更新构建提供显式 Engine 配置。必须避免 storyboard 抢先启动第二个 Engine，
并保留业务权限、URL scheme、插件与原生通道。不要直接用示例 plist 覆盖业务配置。
`ios_integrate.rb --preserve-settings` 仅增加 native 源码和导出符号，不改原签名/部署设置；
并将 Runner 的 plist 设置绑定到专用变量。构建时只覆盖该变量，不把
`INFOPLIST_FILE` 全局传给 CocoaPods，否则插件资源包会错误引用主应用 plist。
热更新打包本身使用配置中的最低 iOS 版本。定制 Engine 若仅支持 Impeller，
热更新专用 plist 需启用 Impeller，不能沿用旧项目的 Skia 禁用项。

## 2. 后台构建并安装一次基线

```sh
./.hotfix/ios/run console --port 8767 --with-delivery
```

按启动提示登录。在“基础版本”选择发行提交并构建，下载 IPA。
后台在独立副本执行完整原生构建，冻结 Dart 基线，替换匹配的 App/Flutter framework，
重新签名，校验冻结 Mach-O 节、原生资源/插件/资产及归档哈希，最后写入完成标志。

开发 IPA 不是网页点开即可安装的 APK。测试设备需由对应 Team 授权并信任开发者。
首次测试可以从归档的 `Payload/Runner.app` 安装：

```sh
xcrun devicectl device install app --device YOUR_DEVICE_ID /path/to/archive/Payload/Runner.app
```

开发描述文件可能短期过期；不要将开发签名 IPA 当正式分发包。
本文没有实现 TestFlight/App Store 上传、企业分发或审核规避。

## 3. 正常开发、生成补丁与发布

保持 App 版本号与基线一致，修复支持范围内的 Dart 代码，测试并提交。
在“补丁构建”选择基线和修复提交，生成后做业务验收，在“发布管理”确认发布。
App 在线下载补丁，下次冷启动生效并上报；“运行结果”查看事件，必要时签名撤回。
**验证补丁时不重新安装 App，不通过 USB 放入补丁文件。**

命令行等价入口为 `./.hotfix/ios/run build`、`patch`、`publish`、`serve`、`status`。
也可显式使用 `hotfix console --platform ios --project /path/to/app --port 8767`。
低层归档入口：

```sh
hotfix release-ios CONFIG OUTPUT
hotfix patch-ios ARCHIVE FIX_COMMIT OUTPUT KEY_DIR PATCH_ID
```

后台保存每个基线的 iOS 未跟踪生成输入及哈希，在生成补丁时恢复对应输入，
仍保留冻结源码/依赖检查；不会放宽原生、插件、依赖和类布局变化门禁。
备份原工程 `.hotfix/console`、专用副本的发行归档以及签名密钥。

## 网络与健康检查

真机的 `127.0.0.1` 指向手机，不是电脑。开发测试显式使用电脑局域网 IPv4、
`--dev-lan`，启动时允许 App 的本地网络访问。正式服务必须 HTTPS。
自动接入加入本地网络 ATS 支持及指定测试 IP 的 Flutter HTTP 例外，
不启用全局 `NSAllowsArbitraryLoads`。不同 iOS 版本仍需实际验证网络权限。

默认健康点是应用启动与首帧完成；真实业务应加入关键页面/依赖检查后再标记健康。
构建、发布成功不代表业务正确或所有用户已更新。

能力范围与 Android 使用同一[兼容性约束](COMPATIBILITY.md)，生产与审核风险见
[安全说明](SECURITY.md)。真机证据应明确区分核心运行时测试与完整在线发布验收。

2026-10-14 已在真实业务工程完成管理 API 按 Git 提交构建、局域网下载、冷启动
健康上报和签名撤回验收，见[设备证据](spikes/ios_spike/DEVICE_EVIDENCE.md)。
这不等于任意 Dart 改动均可发布，也不包含 App Store 分发或全面业务回归。
