# 全平台 Flutter 热更新技术路线

获取日期：2026-09-04。目标平台包括 Android、iOS、OpenHarmony/HarmonyOS、Windows、Linux、macOS 和 Web；当前研发优先级仍为 Android → OHOS → iOS，桌面和 Web 不阻塞前三个平台。

## 1. 核心结论

不能设计“一份补丁跑遍所有平台”。可统一的是发布、安全、状态机和审计协议；执行产物必须按平台生成：

```text
同一份 Dart 变更
    |
    +-- Android -------- 完整、已签名的 libapp.so
    +-- OHOS ----------- 完整、已签名的 libapp.so
    +-- iOS ------------ 非机器码 Patch IR + 内置解释器/AOT linker
    +-- Windows/Linux -- 完整、已签名的 AOT snapshot/library
    +-- macOS ---------- 独立分发可签名 AOT；App Store 走解释器
    +-- Web ------------ 版本化 JS/Wasm 静态资源
```

第一版不做二进制差分。完整产物更容易验证和回滚；只有补丁体积经过真实统计成为问题后，才在传输层增加 bsdiff/zstd，安装后仍校验完整产物 SHA-256。

## 2. 共用平面

### 2.1 构建平面

每个正式 release 保存不可变的 `release descriptor`：源码提交、依赖锁、Flutter/Dart/Engine revision、平台 SDK/NDK、ABI、flavor、channel、全部 build defines、混淆参数和构建脚本摘要。补丁必须从该 descriptor 重放构建。

补丁 manifest 强绑定：

- `appId`、platform、ABI、release/versionCode；
- Flutter、Dart、Engine 的完整 revision；
- flavor、channel、构建参数 SHA-256；
- patch ID、父 patch/release、产物长度和 SHA-256；
- 签名算法、key ID、签发/失效时间、灰度规则和撤回状态。

### 2.2 发布平面

首版只需要对象存储/CDN：

```text
/apps/<appId>/<release>/<platform>/<abi>/patches/<patchId>/artifact
/apps/<appId>/<release>/channels/<channel>/manifest.json
```

离线 P-256 私钥签名规范化 manifest，App 内置公钥。设备用稳定匿名桶执行百分比灰度；发布新 manifest 即可扩量、撤回或切回旧 patch。需要人员审批和多租户隔离时再增加服务端，不提前造控制台。

### 2.3 客户端状态机

```text
BUNDLED -> DOWNLOADED -> VERIFIED -> STAGED -> PENDING_BOOT
    ^                                              |
    |                                    success  v
    +---- last-known-good <- ACTIVE <- HEALTHY ---+
                ^                    |
                +---- BLACKLIST <----+ crash/incomplete boot
```

下载在已验证版本运行期间异步进行。启动只读本地状态，不依赖网络；网络、磁盘、解析、验签或加载失败都运行 last-known-good，否则运行包内 baseline。安装使用同目录临时文件、fsync 和原子 rename；Engine 启动前再次核对最终 inode、长度和 SHA-256。

## 3. 各平台执行后端

| 平台 | 第一技术路线 | Engine 改造 | 主要风险 |
|---|---|---:|---|
| Android | app 私有目录完整 `libapp.so` | spike 可不改；生产建议小改 | OEM/SELinux、snapshot 混装、Play 政策 |
| OHOS | app sandbox 完整 `libapp.so` | 需要 | linker namespace、签名/市场策略、loader 缺少路径校验 |
| iOS | Patch IR 解释执行，未变函数复用包内 AOT | Dart SDK/VM 深度改造 | GC/异常/isolate/FFI、性能、审核 |
| Windows | 完整 AOT library/snapshot | 小型 embedder 改造 | 文件占用、杀软、签名与更新原子性 |
| Linux | 完整 `libapp.so` | 小型 embedder 改造 | 发行版 ABI、挂载 `noexec`、打包格式 |
| macOS | 独立分发：Developer ID 签名/公证 AOT；App Store：解释器 | 分发模式决定 | Hardened Runtime/library validation、审核 |
| Web | CDN 版本化 JS/Wasm + Service Worker | 不改 Engine | 缓存一致性、回退、正在运行页面迁移 |

### 3.1 Android

Flutter 3.41.9 的 `FlutterLoader` 已接受应用内部 files 目录中的 `--aot-shared-library-name=<absolute.so>`，`SettingsFromCommandLine` 收集候选库，`DartSnapshot::SearchMapping` 按顺序解析四个 snapshot symbol。因此第一步先用 stock Engine 证明外部完整 `libapp.so` 可启动，不使用反射。

生产版仍建议做一个最小 Engine/embedder 改造：一次打开并固定一个已验证文件句柄，从同一个 library 获取四个 snapshot symbol，再整体提交给 VM。原因是 stock resolver 分别查找四个 symbol，损坏库理论上可能让不同 symbol 落到不同候选库；安全边界不能依赖“通常会完整”。

Android 验收必须覆盖 baseline、有效 patch、逐字段版本不匹配、截断/篡改、未知 key、磁盘满、进程在 rename 中被杀、启动前崩溃、健康检查后崩溃、黑名单和服务端撤回。Google Play 分发前单独进行政策审核；技术可加载不等于商店允许任意功能变化。

### 3.2 OpenHarmony/HarmonyOS

现有 OpenHarmony-SIG 链路为 ArkTS `FlutterLoader` → `FlutterNapi.init` → C++ `OhosMain::Init` → `SettingsFromCommandLine` → snapshot resolver。release 构建把 `libapp.so` 放入 HAP 的 ABI library 目录。

OHOS 不直接照搬 Android loader。先实现两个 spike：

1. 确认目标系统的 app linker namespace 是否允许从应用可写 sandbox `dlopen`；
2. 确认应用市场签名/审核是否允许这种产物。

通过后，在 ArkTS 和 C++ 两侧增加单一 `verified_aot_path`，C++ 做 canonical path、普通文件、owner/mode、无 symlink、完整 symbol 集和 revision 校验，再把同一 library handle 的四个 mapping 交给 VM。失败直接使用 HAP 内的 baseline。

### 3.3 iOS

iOS 不下载 `.dylib`、`App.framework` 或新的 ARM64 指令。Store release 中同时包含：

- 原始 Dart 程序的签名 AOT baseline；
- Patch IR 解释器；
- baseline 函数/类型/常量元数据；
- AOT 与解释代码之间的调用桥和 patch dispatch table。

补丁编译器同时读取 baseline descriptor 与新程序，生成稳定函数 ID、兼容性检查结果和只含变化部分的非机器码 Patch IR。运行时优先调用 baseline AOT 中可证明等价的函数；变化函数进入解释器。

iOS 按以下顺序推进，任何一级失败都停止产品化：

1. 纯函数：整数、字符串、分支、循环、静态调用；
2. 对象字段、虚调用、闭包、泛型和常量池；
3. async/await、异常和 stack trace；
4. GC root、write barrier、safepoint 与 deoptimization 边界；
5. isolate、消息传递和 background isolate；
6. FFI：第一版只允许调用 baseline 已声明的 FFI，禁止新增 native symbol/signature；
7. Flutter framework/widget 回归、性能与内存基准；
8. App Review/法律书面评估。

最大技术难点不是“写一个 Dart 语法解释器”，而是让解释帧与 AOT 帧共享同一对象模型、GC 和异常语义，并在编译器优化后仍能稳定识别、链接 baseline 函数。实现必须基于上游 `dart-lang/sdk`；Shorebird 的公开架构只作为验证路线可行性的先例，不依赖其不可获得源码。

### 3.4 Windows 与 Linux

复用 Android/OHOS 的完整 AOT 产物模型和共同 verifier。平台 runner/embedder 在创建 Engine 前选择已验证 snapshot/library mapping。Windows 额外处理 DLL/文件占用，采用版本目录和指针文件切换；Linux 检测文件系统 `noexec`、glibc/发行版与 CPU ABI。先支持自部署包，再研究商店包。

### 3.5 macOS

拆成两个产品配置：

- Developer ID 独立分发：研究对补丁库进行 Developer ID 签名与公证，并保持 Hardened Runtime/library validation；不默认关闭安全 entitlement。
- Mac App Store：沿用 iOS Patch IR 解释器，避免下载 native code。

不能为了热更新默认启用 `disable-library-validation` 或 unsigned executable memory；这会扩大攻击面并改变公证/审核风险。

### 3.6 Web

Web 不接入 native Runtime patch。构建内容寻址的 JS/Wasm 与 assets，channel manifest 指向完整版本；Service Worker 预取并原子切换缓存，加载失败回退上一缓存。正在运行的页面不替换代码，下一次导航或刷新生效。灰度最好由 CDN/边缘路由完成。

## 4. 交付顺序与停止点

1. **共同协议**：manifest、签名、verifier、原子安装、状态机的主机测试。
2. **Android spike**：stock Engine 外部 AOT；通过后补 coherent snapshot mapping，再做重复真机矩阵。
3. **OHOS spike**：先验证 sandbox `dlopen` 与市场边界；任一失败则停止 AOT 路线，转资源/DSL 动态化。
4. **iOS feasibility**：只做 Dart SDK 最小语义 corpus；GC/异常/isolate 任一无法证明正确即停止。
5. **Android/OHOS 生产硬化**：灰度、撤回、观测、演练和合规签字。
6. **iOS 扩面**：只有 feasibility 和审核门都通过才接 Flutter widget 与生产业务。
7. **Windows/Linux/macOS/Web**：复用已经稳定的共同平面，不反向拖慢移动端。

## 5. 明确不做

- 不用反射替换 Flutter 私有字段。
- 不把 Kernel/JIT debug 产物用于生产。
- 不在 iOS 下载未签名机器码。
- 不允许跨 Engine/Dart revision 使用 patch。
- 不用 MD5/CRC 作为安全完整性校验。
- 不在关键加载链路 fail-closed 导致 App 无法启动。
- 不宣称“全平台可用”，直到各平台的重复设备/系统矩阵和商店风险门通过。

## 6. 一手资料

- [Flutter 3.41.9 Android FlutterLoader](https://github.com/flutter/flutter/blob/3.41.9/engine/src/flutter/shell/platform/android/io/flutter/embedding/engine/loader/FlutterLoader.java)
- [Flutter snapshot resolver](https://github.com/flutter/flutter/blob/3.41.9/engine/src/flutter/runtime/dart_snapshot.cc)
- [Flutter AOT operation](https://github.com/flutter/flutter/blob/3.41.9/docs/engine/Flutter-engine-operation-in-AOT-Mode.md)
- [Flutter architecture and embedders](https://docs.flutter.dev/resources/architectural-overview)
- [Flutter supported deployment platforms](https://docs.flutter.dev/reference/supported-platforms)
- [OpenHarmony-SIG FlutterLoader](https://gitee.com/openharmony-sig/flutter_engine/blob/master/shell/platform/ohos/flutter_embedding/flutter/src/main/ets/embedding/engine/loader/FlutterLoader.ets)
- [OpenHarmony-SIG OhosMain](https://gitee.com/openharmony-sig/flutter_engine/blob/master/shell/platform/ohos/ohos_main.cpp)
- [HarmonyOS C/C++ dynamic linker namespace](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/c-cpp-overview)
- [Apple App Review Guidelines 2.5.2](https://developer.apple.com/cn/app-store/review/guidelines/)
- [Apple library validation entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.cs.disable-library-validation)
- [Shorebird public system architecture](https://docs.shorebird.dev/code-push/system-architecture/)
- [Google Play policy responsibilities](https://support.google.com/googleplay/android-developer/answer/9899234)

