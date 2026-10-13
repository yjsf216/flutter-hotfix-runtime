# Android 热更新简化流程

初始化一次，日常只需要 **构建版本 → 生成补丁 → 确认发布**。以下命令都在你的 Flutter App Git 仓库根目录执行。

喜欢图形界面可在完成首次接入后使用[独立管理后台](console/README.md)：选基础版本和 Git 提交，点击生成、发布或撤回。后台自带本机执行器，无需 Jenkins；第一版需在后台重新构建发行基线，不自动导入历史命令行归档。

## 1. 第一次接入

先准备固定的 Flutter 3.41.9、定制 Android arm64 DDM Engine、对应 Dart 源码依赖、Android SDK 和 JDK。它们不会由初始化命令自动下载，详见 [Engine 准备](engine/README.md)。普通 Flutter Engine 不能替代定制 Engine。

```sh
sh /path/to/flutter-hotfix-runtime/tool/hotfix init
```

按提示填写工具链路径、签名密钥目录和补丁服务地址。默认地址是本机测试服务 `http://127.0.0.1:18091`，不是生产服务。

工具会为标准 FlutterActivity 工程接入运行时、生成配置和本地入口，并保存工具链路径。修改前会备份源文件；没有密钥时生成新密钥，不覆盖已有密钥。先查看修改计划可用 `init --dry-run`。

已有 `hotfix.android.json` 时复用配置，前提是原生接入已经完成。自定义 MainActivity、已有 flavors/CMake 等复杂工程不会被强行改写，请按[手动接入说明](MANUAL_INTEGRATION.md)适配，再执行初始化。

检查 Git 差异、运行应用测试，然后自行提交接入代码。工具不会自动提交代码。

## 2. 发布一个新的 App 版本

正常开发，设置 `pubspec.yaml` 的版本号，测试并提交代码，然后执行：

```sh
./.hotfix/run build
```

它会构建并验证 APK、归档基线，记住这次成功构建的版本。将输出提示中的 `app.apk` 按原有流程分发给用户；工具不会自动安装或分发 APK。

简化入口从 `pubspec.yaml` 读取版本，不需要再同步配置中的 `release`。原有低层命令仍使用其显式配置。

## 3. 线上发现问题，生成修复补丁

正常修改支持范围内的 Dart 代码，测试并提交，保持工作区干净，然后执行：

```sh
./.hotfix/run patch
```

工具自动使用上一次成功构建的基线与当前 Git 提交，生成、签名并记录补丁，不会立即上传。无需手填基线路径、补丁编号、输出目录和密钥路径。

不支持的代码变化会被拒绝；这不是任意 Flutter 修改都能热更新。补丁版本号必须与基线一致；原生代码、依赖等变化需要发新安装包。需要修复多个历史版本时，仍使用[低层命令](GIT_WORKFLOW.md)明确选择对应基线，避免误选。

即使只改 Dart 方法，也可能因基线没有保留所需库引用而被拒绝（例如 `unretained module reference`）。新基线已保留其中实际编译到的 Flutter 框架公共 API，并支持嵌套常量映射；已有旧基线不会因此自动扩展。新的依赖或未保留的 SDK 库仍可能需要新安装包。快捷入口不会绕过编译器的边界检查。

## 4. 验收后发布

先在测试环境验收，再执行：

```sh
./.hotfix/run publish
```

工具展示服务地址、App 版本、基线和补丁编号，确认后才上传。地址取自基线归档，不会随当前配置悄悄改变。生产发布凭据通过 `HOTFIX_PUBLISH_TOKEN` 环境变量或交互输入提供，不保存到项目配置。CI 可使用 `publish --yes`，并由 CI 安全注入凭据。

上传成功只代表服务端接收，不代表用户已应用；还需验证下载、下次启动生效和实际业务结果。

## 5. 本机测试服务

使用默认本机地址时，在另一个终端进入同一 App 目录，运行：

```sh
./.hotfix/run serve
```

它自动读取公钥并保存仅供本地测试的发布凭据，之后 `publish` 自动使用。服务在前台运行，按 Ctrl+C 停止。

如需手机验收，明确选择自己的测试设备，再手动执行：

```sh
adb -s YOUR_TEST_DEVICE_SERIAL reverse tcp:18091 tcp:18091
```

安装基线 APK 后生成并发布补丁：第一次启动检查下载，下一次冷启动检查生效。完成后可用 `adb -s YOUR_TEST_DEVICE_SERIAL reverse --remove tcp:18091` 移除转发。快捷命令不会自动操作设备。

### 使用 Wi-Fi 局域网（无需 USB 转发）

首次接入时明确开启开发模式，并填写电脑的私有 IPv4 地址：

```sh
sh /path/to/flutter-hotfix-runtime/tool/hotfix init --dev-lan --origin http://192.168.1.100:18091
sh /path/to/flutter-hotfix-runtime/tool/hotfix console --with-delivery
```

手机与电脑需能通过局域网互相访问。服务仅绑定配置中的电脑 IP；管理后台仍绑定
`127.0.0.1`。工具只允许 RFC1918 的 IPv4 地址，默认仍拒绝局域网明文 HTTP。
自动接入生成的 Android 网络策略仅允许该 IP，不允许任意域名或子域明文访问。

已有接入配置不会自动改写。要切换测试地址，需要在 `hotfix.android.json` 设置
`updateOrigin`、`allowDevelopmentHttp: true`、`allowDevelopmentLan: true`，并把测试 flavor 的
`hotfix_network_security.xml` 中 domain 改成同一个精确 IP。审查、提交后重新构建并安装基线，
旧 APK 的服务地址不会改变。电脑 IP 变化也需要更新地址并重新构建基线，推荐固定 DHCP 租约。

局域网 HTTP 仅用于可信测试网络，不提供传输加密。不要使用生产发布凭据，不要将该服务
暴露公网；正式分发使用 HTTPS。请勿为了连通而关闭整个系统防火墙。

## 查看状态与注意事项

```sh
./.hotfix/run status
./.hotfix/run --help
```

- `.hotfix/` 在本机 Git 排除规则中忽略，保存路径、备份、归档和可能存在的密钥/测试凭据。不要强行提交或分享整个目录；基线和签名密钥需要安全备份。
- 新的 `build` 或 `patch` 尝试会清除待发布选择，即使失败也不会误发旧补丁；已有归档文件保留。
- 从构建基线到生成补丁，需要保留相同的运行时与工具源码。更新工具后应构建新基线，或使用原来的工具快照。
- 自动接入默认以首帧作为最小健康检查，正式接入应替换成真实业务启动检查。
- 当前是实验性 Android arm64 流程，不包含生产 HTTPS 部署、全项目任意更新、iOS 自动接入或应用商店审核保证。

详细参考：[手动接入与排错](MANUAL_INTEGRATION.md) · [Git 工作流与发布控制](GIT_WORKFLOW.md) · [服务 API](delivery/README.md)。
