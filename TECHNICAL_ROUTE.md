# Android、iOS、OHOS 统一 Patch IR 路线

获取日期：2026-09-04。产品后端统一为“安装包内 baseline AOT + 内置 Patch IR 解释器 + AOT linker”，顺序为 Android 开发验证 → iOS 移植 → OHOS 移植。

## 执行模型

业务继续书写普通 Dart，不使用注解、wrapper、代理类或手工注册。定制 Dart frontend/compiler 自动完成：

```text
普通 Dart 源码
  -> 稳定 ClassId / FunctionId
  -> patch points + dispatch table
  -> baseline AOT + linker metadata

新源码 + baseline metadata
  -> 类级组织、函数级 diff
  -> 已签名非机器码 Patch IR

运行时调用
  -> 未变化函数：安装包内 baseline AOT
  -> 变化/新增函数：Patch IR interpreter
```

AOT linker 只把函数 ID 映射到安装包内已有 AOT entry，不加载补丁机器码。外部 `libapp.so` 仅保留为 Android/OHOS 加载链路研究和性能基准，不是商店生产后端。

## 第一版目标语言边界（并非全部已实现）

允许：

- 修改已有方法体、构造逻辑、Widget `build` 和 async 业务逻辑；
- 新增仅由补丁代码调用的函数和类；
- 调用 baseline 中已经存在且签名未变的 Dart/native 能力。

拒绝：

- 修改实例字段布局、继承关系、mixin、泛型结构、已有方法签名或 enum 布局；
- 新增或修改 native plugin、FFI symbol/signature；
- 跨 Flutter、Dart、Engine revision 或构建参数使用补丁。

可更新业务 package 禁止跨函数内联，调用经 dispatch table；Flutter Framework、Dart SDK 和固定依赖保持普通 AOT 优化。新增类第一版只能在 Patch IR 内创建、持有和调用，不暴露给 baseline AOT，也不参与 native/FFI ABI。

当前自动编译链已验证同布局字段、闭包、命名/可选参数、async、普通 `sync*`/`async*`、异常和既有 AOT 调用；generator 使用原生 `yield*` 保留惰性执行、取消与 finally 语义。构造逻辑更新、新类、泛型（含泛型 generator）、dynamic 与 lexical `super` 的补丁支持仍待实现，当前明确拒绝，不视为完成。

## 共用安全与发布平面

签名 manifest 强绑定 appId、platform、ABI、release、Flutter/Dart/Engine revision、flavor、channel、构建参数摘要、baselineId、patchId、父版本、IR 长度和 SHA-256。离线私钥签名；网络、CDN 和磁盘均不可信。

首版控制面只有不可变对象和静态签名 channel manifest。客户端异步下载并验证，使用同目录临时文件、fsync 和原子 rename。启动状态为：

```text
BUNDLED -> VERIFIED -> STAGED -> PENDING_BOOT -> HEALTHY -> LAST_KNOWN_GOOD
                              |                    |
                              +-- incomplete/crash+-> BLACKLIST -> fallback
```

任意网络、解析、验签、版本、IR 校验、磁盘或启动失败都继续运行 last-known-good，否则运行包内 baseline。

## 编译器与 Runtime 分层

### Frontend/compiler

- 以 library URI、声明路径、类名、成员名、kind 和规范化签名生成稳定 ID；方法体变化不改变 FunctionId。
- 保存 baseline 的类布局、签名、常量、函数和优化约束元数据。
- 对新程序做结构兼容检查，先拒绝再生成 IR。
- 以类组织 manifest，实际只携带变化/新增函数。
- 对可更新业务代码插入 dispatch；禁止会绕过 patch point 的跨函数内联。

### Patch IR

产品 Patch IR 以固定 Dart revision 的上游 DBC3 bytecode 为基础，而不是长期维护自定义 opcode。Dart 3.11.5 已包含实验性的 `dart2bytecode`、dynamic module loader、KBC interpreter、解释↔AOT 调用、GC root visitation 和异常/async 栈支持；Flutter product Runtime 必须显式以 `dart_dynamic_modules=true` 重建。

当前 JSON opcode 仅保留为独立语义 oracle。2026-09-09 已打通普通 Dart → Kernel AST 比较与 clone → 自动 AOT patch points + DBC3 → OpenSSL P-256 签名 → 启动重验与执行。Runtime 使用包内公钥验证全部身份字段和实际产物摘要，baselineId 绑定独立 baseline Kernel、编译器变换源码与 AOT 编译器二进制。上游 dynamic-interface 标注保留 baseline 能力，编译边界拒绝未保留的引用。

发布与补丁编译已分离：发布时冻结原始 Kernel、AOT Kernel、接口约束和 release descriptor；以后仅凭冻结文件和更新源码生成 DBC3，不重编译已安装基线。测试覆盖覆盖原源码、移走旧入口后仍能产出有效补丁。真实 Flutter `StatelessWidget.build` 已通过 `target=flutter`、product `dart:ui` 的 AOT/DBC3 产物门，但尚未在 Flutter Engine 内加载或渲染。

### AOT linker/bridge

- DBC3 模块入口返回 `FunctionId -> interpreted closure` 表；Runtime 全量校验后一次性激活，不直接依赖 VM 私有 Function 查找 API；
- `IR -> IR`：dispatch 到补丁函数；
- `IR -> AOT`：按 FunctionId 调用 baseline entry；
- `AOT -> IR`：baseline patch point 查 dispatch table；
- `AOT -> AOT`：无 patch 时走快速路径。

Dynamic module 声明在 isolate group 内只加载一次，而 dispatch 表是 isolate-local；主 isolate 验证并加载后，将不可变 closure 表发送给各子 isolate 激活。子 isolate 不重复加载同一 module URI。

解释帧必须纳入 Dart GC root、write barrier、safepoint、异常展开和 stack trace。这里是 iOS 可行性的核心停止门，不用业务层对象代理规避 VM 语义。

## 平台策略

| 平台 | 统一部分 | 平台差异 | 商店边界 |
|---|---|---|---|
| Android | Patch IR/compiler/linker/runtime；独立 arm64 product VM 已交叉编译 | Flutter Android Engine、文件与启动状态存储 | Google Play 禁止外部 `.so/.dex/.jar`，解释器路线仍需政策审核 |
| iOS | 同一 Patch IR/compiler/linker/runtime；arm64 VM core 已编译 | Flutter iOS Engine 真实链接、代码签名和异常栈适配 | 不下载 ARM64、`.dylib` 或 `App.framework` |
| OHOS | 同一 Patch IR/compiler/linker/runtime | ArkTS/N-API embedder、sandbox 与 linker namespace | 华为/OpenHarmony 市场规则单独审核 |

Android 是低成本研发平台：先验证 IR、dispatch、AOT bridge、GC 和异常语义，再移植同一核心到 iOS；OHOS 最后只做平台接入和完整回归，不另造执行模型。

共用 C 存储层已接入签名加载器，使用 `openat/O_NOFOLLOW`、有界单描述符读取、文件/目录 fsync、原子 rename 和目录 inode 锁。Android APK 已实际包含存储库并通过导出符号/16 KiB 段对齐检查；iOS 静态链接保留 FFI 入口、OHOS CMake 共享库也已验证。它们是安装包内原生代码，不是下发补丁；完整 iOS App/OHOS HAR 和三端 Engine 执行门仍未完成。

Flutter 3.41.9 Engine 已原生提供 `tools/gn --dart-dynamic-modules`，并包含 Android arm64/x64 与 iOS 真机/模拟器的 DDM release/debug CI 配置及 `-ddm` 打包规则；Android/iOS 不新增 GN 抽象，只沿用该实验构建通道。OHOS 锁定的 Dart 3.6.2 同样已含 DBC3/KBC，旧 Engine 可用现有 `--gn-args=dart_dynamic_modules=true` 透传；下一门是实际 arm64 HAR 构建。

## 里程碑与停止门

1. **语义 spike（已通过）**：Dart CFE 把普通 fixture 编译为 Kernel；自动生成稳定 ID；单方法 diff；最小 IR；baseline/AOT 与 patch/interpreter dispatch；坏签名、baselineId、签名结构和 IR 均 fail-open。
2. **Dart frontend 接入（host driver 已通过）**：`compileToKernel` 后使用上游 AST equivalence、clone 和 DBC3 codegen，插入 patch points 后运行 AOT 全局优化；继续接入 Flutter 实际 frontend 工具链。
3. **AOT patch points**：业务 package 禁止跨函数内联并生成 dispatch table；性能损失超过预算则重新划定可更新 package，而不是全局关闭优化。
4. **上游 dynamic modules（host VM 已通过）**：锁定 Dart 3.11.5 VM 以 `dart_dynamic_modules=true` 构建成功；上游 `core_api` 与仓库内 FunctionId 用例已验证 `AOT -> DBC3 closure -> AOT`；下一门是 Flutter Engine 与三平台构建。
5. **VM 正确性**：复用并扩展上游字段、虚调用、闭包/泛型、async/异常、GC root、barrier、safepoint、isolate 测试；任何偶发内存错误都停止产品化。
6. **Flutter 集成**：Widget、element/state、frame、plugin baseline API 回归。
7. **Android 生产门**：灰度、撤回、崩溃回滚、审计、Play 政策评估。
8. **iOS 与 OHOS**：复用同一 corpus，分别通过平台和市场门后才声明支持。

## 一手资料

- [Flutter AOT operation](https://github.com/flutter/flutter/blob/3.41.9/docs/engine/Flutter-engine-operation-in-AOT-Mode.md)
- [Dart upstream dart2bytecode](https://github.com/dart-lang/sdk/tree/3.11.5/pkg/dart2bytecode)
- [Dart upstream dynamic modules](https://github.com/dart-lang/sdk/tree/3.11.5/pkg/dynamic_modules)
- [Flutter snapshot resolver](https://github.com/flutter/flutter/blob/3.41.9/engine/src/flutter/runtime/dart_snapshot.cc)
- [Shorebird system architecture](https://docs.shorebird.dev/code-push/system-architecture/)
- [Shorebird public code-push design notes](https://github.com/shorebirdtech/shorebird/blob/main/NOTES_ON_CODEPUSH.md)
- [Google Play Device and Network Abuse policy](https://support.google.com/googleplay/android-developer/answer/16559646)
- [Apple App Review Guidelines 2.5.2](https://developer.apple.com/cn/app-store/review/guidelines/)
- [OpenHarmony-SIG FlutterLoader](https://gitee.com/openharmony-sig/flutter_engine/blob/master/shell/platform/ohos/flutter_embedding/flutter/src/main/ets/embedding/engine/loader/FlutterLoader.ets)
