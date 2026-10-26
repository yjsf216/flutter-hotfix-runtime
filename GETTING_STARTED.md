# Android 热更新：五步开始使用

> 本文 `init` 仍是原仓库接入流程。已切换独立 `patch_runtime` 的 App 不应重新运行旧 `init`；
> 当前迁移边界见 [PROJECT_LAYOUT.md](PROJECT_LAYOUT.md)。

iOS 使用同一套后台和简化命令，初始化与签名步骤见 [iOS 使用指南](IOS_GETTING_STARTED.md)。

默认使用自带网页后台和内置构建执行器，无需 Jenkins、数据库或前端开发环境。
也可使用命令行，底层构建、签名和分发能力完全相同。

## 1. 检查工具链

```sh
sh /path/to/flutter-hotfix-runtime/tool/hotfix doctor --guide
```

缺什么会一次列出，并给出安装指引。首次使用按[工具链准备](TOOLCHAIN_SETUP.md)配置
固定 Flutter 3.41.9、匹配的 Dart 源码、定制 Android arm64 DDM Engine、Android SDK 和 JDK。
`patch_runtime` 0.2.0 起随 Git 包提供配套 Android/iOS arm64 Release Engine，Pub 拉取后自动校验使用；
不支持的宿主/目标组合仍需源码构建。Dart 补丁编译工具链另行准备。后台随仓库提供预构建页面。

## 2. 初始化 App

进入自己的 Flutter App Git 根目录：

```sh
sh /path/to/flutter-hotfix-runtime/tool/hotfix init
```

填写工具路径和补丁服务地址。标准 FlutterActivity 工程会生成接入配置、启动入口、
签名密钥及项目入口 `./.hotfix/run`；原文件先备份。审查改动、测试并自行提交接入代码。
先看修改计划可用 `init --dry-run`。

`hotfix.android.json` 和 `hotfix.ios.json` 只需维护相同的公共字段：工程/入口、平台、补丁范围、
业务 `dartDefines`、更新/编号/CDN 地址及网络策略。包名、Android 渠道、iOS 签名团队、Scheme、
最低系统版本在打包时从 Gradle/Xcode 读取，不需要重复填写。版本号由简化入口读取 `pubspec.yaml`。
Android 优先将显式 `APP_CHANNEL` 与真实 flavor 精确匹配；多个候选无法确定时会停止，要求
填写可选的 `native.flavor` 或 `native.scheme`，不会默认选第一个。最终参数保存在归档的
`resolved-config.json`，补丁使用冻结归档，不重新猜测原生参数。

只检查自动解析结果（不打包、不签名、不发布）：

```sh
python3 /path/to/flutter-hotfix-runtime/tool/project_config.py hotfix.android.json
python3 /path/to/flutter-hotfix-runtime/tool/project_config.py hotfix.ios.json
```

手机通过 Wi-Fi 测试时，直接指定电脑局域网地址：

```sh
sh /path/to/flutter-hotfix-runtime/tool/hotfix init --dev-lan --origin http://192.168.1.100:18091
```

默认 127.0.0.1 只指向设备自己，手机使用它需要 USB 转发。正式服务填写 HTTPS origin。
自定义 MainActivity、flavors、CMake 等工程按[手动接入](MANUAL_INTEGRATION.md)合并，工具不会强行覆盖。

## 3. 启动后台

```sh
./.hotfix/run console --with-delivery
```

打开终端提示的地址（默认 http://127.0.0.1:8765），用提示的 access-token 文件内容登录。
--with-delivery 同时启动开发 HTTP 分发服务；已有服务或使用 HTTPS 时去掉此参数。
管理页面只监听电脑本机。生产发布凭据通过 HOTFIX_PUBLISH_TOKEN 环境变量注入服务端。

## 4. 构建并分发基础版本

在“基础版本”选择发行 Git 提交，点击构建，成功后下载 APK，按原有渠道分发或安装到测试手机。
后台自动归档基线，并在专用副本构建，不切换你的开发工作区。

只有该基线生成的 APK 才能接收对应补丁，普通 APK 无法事后补上热更新能力。
第一版后台暂不导入旧命令行归档，首次使用后台需要新建基线。

## 5. 修复、生成补丁、发布

1. 正常修改 Dart 代码、测试并提交，保持与基线相同的 App 版本号。
2. 在“补丁构建”选择基础版本和修复提交，点击生成。
3. 测试验收后，在“发布管理”核对目标并确认发布。
4. App 检查下载，在下次冷启动生效；在“运行结果”查看上报，必要时撤回。

验证热更新时只安装一次基线 APK，修复后不要再安装新 APK。
发布成功不等于用户已生效；运行结果是事件数，不是独立用户数或用户成功率。

## 命令行用户

初始化后，以下入口都在 App 根目录使用：

| 命令 | 用途 |
|---|---|
| `./.hotfix/run doctor` | 复查 App 保存的工具链配置 |
| `./.hotfix/run build` | 构建当前提交的 APK 与基线 |
| `./.hotfix/run patch` | 相对最近成功基线生成当前提交的补丁 |
| `./.hotfix/run publish` | 展示目标，确认后上传 |
| `./.hotfix/run serve` | 单独启动开发分发服务 |
| `./.hotfix/run status` | 查看最近基线和补丁 |

多历史版本优先在后台选择，或使用[低层 Git 工作流](GIT_WORKFLOW.md)。
后台基线和命令行最近基线各自管理，不会静默互换。

## 常见问题

- 不是任意 Dart 改动都支持。原生、依赖、签名、类布局、新导入等不兼容变更会拒绝，需要新 APK。
  详见[能力边界](COMPATIBILITY.md)。Git 提交中不受支持的其他文件改动也会拒绝。
- 地址写入基线。已有工程改局域网地址，需修改 hotfix.android.json 的 updateOrigin、
  allowDevelopmentHttp: true、allowDevelopmentLan: true，同步 Android 测试网络配置并提交，再构建新基线。
  电脑 IP 改变后也需处理，建议固定 DHCP 租约。
- 局域网 HTTP 仅用于可信测试网络，只允许显式配置的 RFC1918 私有 IPv4；正式服务使用 HTTPS。
- 安装签名冲突时不要卸载已有 App 强行安装，先核对签名，避免丢失数据。
- 依赖下载可使用自己的代理配置；工具不会关闭证书校验或自动修改系统代理。
- 旧基线需要匹配的工具版本。SDK、归档、私钥和 .hotfix 状态需备份，不能只备份 Git。

更多说明：[后台 API 与运维](console/README.md)、[分发服务](delivery/README.md)、
[干净示例验收](examples/console_quickstart/README.md)。
