# 项目结构与维护入口

本文件记录 2026-10-23 的整理状态。它是目录和操作导航，不替代兼容性检查、
签名校验或真机验收。历史实验结论不能作为独立运行时新版本的验收结果。

## 三个边界

| 工程 | 职责 | 不负责 |
|---|---|---|
| `flutter-hotfix-runtime`（本仓库） | 基线/补丁编译、签名、上传工具、本机构建后台、分发服务、工具链与实验回归 | 不应成为已迁移 App 的源码路径依赖 |
| `flutter-patch-runtime`（独立仓库） | App 内的验签、下载、存储、加载、健康确认、回滚，以及必要原生代码 | 不包含管理网站、补丁编译器、完整 SDK 或签名私钥 |
| 接入的 Flutter App | 正常业务开发、平台工程、启动与业务健康检查 | 不复制补丁下载和验签实现 |

独立 Dart 包名为 `patch_runtime`，其内部包含固定版本的 `dynamic_modules` 包。
从 0.2.0 起，独立仓库还分发 `engine/3.41.9-ddm.1` 的 Android/iOS arm64 Release 制品，
配套快照工具仅适用于 macOS arm64。构建工具通过 Pub 包目录定位并校验，不需要本机 Engine 源码树。
后者是配套 SDK 的接口，不是完整 VM；普通 Flutter Engine 不能替代定制 Engine。
App 的源码依赖边界与构建机器的工具链依赖是两回事：制作基础包/补丁仍需构建工具和匹配 Engine。

## 本仓库目录

| 位置 | 当前用途 | 维护规则 |
|---|---|---|
| `tool/` | 命令入口、平台打包、自动配置解析、上传、环境诊断 | 修改后运行对应 `*_check.py`；工具指纹变化需新基线或匹配旧工具 |
| `ci/` | 独立 CI 基线登记、补丁租约、清理预览适配 | 默认不清理；未改现有 Jenkins 任务，见 [CI 说明](ci/README.md) |
| `spikes/patch_ir_spike/tool/` | 现有 Kernel/DBC3 编译器、签名工具和回归 | 名称历史遗留，但仍是实际构建路径，不是可删除缓存 |
| `spikes/patch_ir_spike/lib/` | 旧运行时与协议实现 | 供旧流程、服务端复用及回归；与独立包的安全修复需明确同步并测试 |
| `native/` | 旧流程的 C 存储实现与测试 | 为旧基线保留；新 App 使用独立包的 native 源码 |
| `engine/` | 定制 Engine 构建脚本、上游补丁、证据 | 不上传 Engine 二进制、Apple SDK 或本机工具链 |
| `console/` | 本机网页、管理 API、串行构建任务执行器；含 hosted 页面源码 | 前端源码改动后重建对应 `static/`，源码与生成资源配套提交 |
| `delivery/hosted/` | 服务端上传、对象存储/CDN、基线登记与发布管理 | 服务端不持有补丁签名私钥，不执行 App Git 构建 |
| `examples/`、其他 `spikes/` | 示例、实验和有限验收 | 与 App 发布流程区分，不把实验通过当成任意项目可用 |
| `work/`、`outputs/` | 本机 SDK、工具源码备份、实验产物 | Git 忽略；不是可以无条件清空的目录 |

根目录文档暂不大规模移动，避免破坏已有链接和命令中的相对路径。

## 从哪里开始

| 任务 | 文档 |
|---|---|
| 准备固定工具链 | [TOOLCHAIN_SETUP.md](TOOLCHAIN_SETUP.md) |
| 旧接入流程与本机网页构建 | [GETTING_STARTED.md](GETTING_STARTED.md)、[console/README.md](console/README.md) |
| 自定义 App 接入 | [MANUAL_INTEGRATION.md](MANUAL_INTEGRATION.md)、[IOS_GETTING_STARTED.md](IOS_GETTING_STARTED.md) |
| 独立运行时接入 | 独立 `flutter-patch-runtime` 仓库的 README；当前通用 `init` 尚未迁移 |
| Git 基础版本与补丁 | [GIT_WORKFLOW.md](GIT_WORKFLOW.md) |
| 上传基础包/补丁、网页发布、CDN | [delivery/hosted/README.md](delivery/hosted/README.md) |
| 支持范围与安全边界 | [COMPATIBILITY.md](COMPATIBILITY.md)、[SECURITY.md](SECURITY.md) |
| 历史设计和阶段计划 | [ARCHITECTURE.md](ARCHITECTURE.md)、[PLAN.md](PLAN.md)；不是当前协议的唯一依据 |

## 配置归属

App 的 `hotfix.android.json` 与 `hotfix.ios.json` 使用同一组公共字段：

- `project`、`entry`、`patchScope`、`platform`：工程、入口和补丁范围。
- `dartDefines`：业务构建选择，不能自动猜测测试/正式环境。
- `updateOrigin`：编译进基础包的更新服务地址。
- `artifactBase`：编译进基础包的补丁分发/CDN 地址。
- `patchNumberingOrigin`：构建机器申请 p1/p2 编号的服务地址，不是 App 下载地址。
- `allowDevelopmentHttp` / 可选 `allowDevelopmentLan`：明确的开发网络授权。

包名从原生工程读取；Android 渠道从真实 Gradle variant 选择，只有显式
`APP_CHANNEL` 与 flavor 精确一致或只有一个候选时自动决定。iOS 的 Scheme、团队、最低版本
从 Xcode 的 Release 有效设置读取；识别启用了运行时的专用 Info.plist。
多候选或配置缺失时停止，不选择第一个、不创建或撤销签名证书。
必要时使用可选 `native` 覆盖；已有旧平铺字段仍可读取，禁止与 `native` 混写。

```sh
python3 tool/project_config.py /path/to/app/hotfix.android.json
python3 tool/project_config.py /path/to/app/hotfix.ios.json
```

上述命令只解析设置，不打包、签名、发布或操作设备；Gradle/Xcode 仍可能生成自身缓存。
简化构建入口从 `pubspec.yaml` 读取版本；底层 release 命令仍需明确 `release`。
实际构建参数保存在新归档的 `resolved-config.json` 和发行记录中。
修改 JSON 不会改变已安装的 App；旧补丁继续依赖旧基线的冻结输入。

## 提交顺序与未完成事项

独立运行时已提交并推送，接入 App 已改为固定完整 Git SHA，两个 Dart 包均解析到 Git 缓存。
这不等于主工程和 App 的其余工作区改动已提交、推送或部署；新基础包真机验收仍待完成。

1. **独立运行时仓库**：审查 `lib/`、`native/`、`third_party/`、测试、许可证、来源哈希和接入说明；
   提交并推送后，使用固定完整 Git SHA，不能用可移动分支名充当已冻结依赖。
2. **App 接入分支**：固定上述 Git SHA，重新解析依赖；验证 Android CMake
   和 iOS Pod 均从解析后的包目录读取源码，不再依赖旧工程路径。不得改写旧基础分支。
3. **构建工具改动**：自动原生配置解析、Android/iOS 打包、相关测试和文档成组提交；
   `project_config.py` 与调用它的入口不可漏交。旧基线需保留匹配旧工具，不能更新指纹绕过校验。
4. **分发/后台改动**：编号、基线登记、软删除、时间显示、上传/CDN、独立网页及配套测试单独审查，
   检查新生成的静态页面和资源文件引用一致后再提交。提交代码不等于更新线上服务。
5. **最后验收**：拆分和配置自动化后的新基础包、新补丁需要 Android/iOS 真机闭环；
   当前宿主与原生模块检查不能替代这一步。通用 `init` 切换独立包仍是后续工作。

此前的已验证安装包/补丁，不会因为整理源码而自动变成新版本。

## 最小检查清单

本仓库配置/打包逻辑检查（不签名真实 App、不操作设备；iOS 接入检查需 Ruby/xcodeproj）：

```sh
python3 -B tool/project_config_check.py
python3 -B tool/app_cli_check.py
python3 -B tool/android_release_check.py
python3 -B tool/ios_release_check.py
python3 -B tool/ios_integration_check.py
```

独立运行时的分析、签名、存储和生命周期测试见该仓库 README。
编译器联通测试为 `spikes/patch_ir_spike/tool/extracted_runtime_check.dart`，需要固定宿主工具链。
涉及后台/分发时另跑对应回归，不能只以配置测试通过作为发布依据。

## 不提交、不随意清理

- IDE 状态、缓存和构建目录不进入源码提交；忽略规则不会删除本机文件。
- Token、私钥、证书、业务日志、设备数据、APK/IPA、完整 SDK 不放进源码仓库。
- App 的 `.hotfix/` 中有基础包归档、签名密钥和发布状态，必须单独备份，不能只保存 Git。
- 备份、旧运行时与实验目录只有在确认不再承担基线兼容或验收用途后才可清理。
