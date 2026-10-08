# Flutter 热更新接入与发布指南（实验性）

第一次使用请先读[Android 简化流程](GETTING_STARTED.md)；自定义工程见[手动接入与排错](MANUAL_INTEGRATION.md)。本文作为配置、代码位置和低层命令参考。

本文面向已接入本运行时的 Flutter 项目，不绑定具体业务 App。
目前的统一 APK 构建入口支持 Android arm64；不是对任意 Flutter 工程的一键接入，
也不是生产安全认证。iOS 的历史实验不代表已具备相同的发布能力或审核结论。

## 先理解日常流程

1. **发布 A**：从干净的 Git 提交构建带热更新能力的 APK，同时保存完整基线归档。
2. **修复 B**：正常修改业务 Dart 源码、测试并提交；不手写字节码，不必修改诊断文件。
3. **生成补丁**：指定 A 的归档和 B 的提交，工具检查兼容性、编译并签名。
4. **测试与发布**：在安装 A 的测试设备验收后，显式上传补丁，再按需要灰度放量。
5. **用户生效**：App 检查并下载补丁，下次冷启动生效；启动健康确认与失败恢复由运行时处理。

普通 Flutter 安装包若没有预先集成此运行时，不能事后直接接收这种补丁。
新增/删除/重命名文件、类字段布局、构造器、方法签名、原生代码、资源和依赖等
不兼容改动需要新基线。`patchScope: lib` 不等于任意 Dart 修改均可热更新。
当前 Git 检查也会拒绝混入的文档等非补丁文件；补丁提交范围应保持清晰。

## 文件在哪里，各自做什么

| 位置 | 职责 |
| --- | --- |
| [tool/hotfix](tool/hotfix) | 命令行统一入口；不会自动提交 Git、安装设备或发布补丁 |
| [tool/android_release.py](tool/android_release.py) | Android APK 打包、基线归档和产物核验 |
| [project_cli.dart](spikes/patch_ir_spike/tool/project_cli.dart) | 基线/补丁编译、Git 校验及签名命令编排 |
| [delivery_server.dart](spikes/patch_ir_spike/tool/delivery_server.dart) | Dart HttpServer 补丁服务：上传、查询、下载、撤回、报告和统计 |
| [delivery_publish.dart](spikes/patch_ir_spike/tool/delivery_publish.dart) | 上传签名清单和字节码，不上传私钥 |
| [delivery_control.dart](spikes/patch_ir_spike/tool/delivery_control.dart) | 签署灰度/撤回策略，执行暂停、恢复及查询统计 |
| [update_client.dart](spikes/patch_ir_spike/lib/update_client.dart) | App 内检查、下载、重试和上报客户端 |
| [signed_patch_loader.dart](spikes/patch_ir_spike/lib/signed_patch_loader.dart) | 验签、加载及健康确认 |
| [patch_store.dart](spikes/patch_ir_spike/lib/patch_store.dart) | 本地补丁选择、健康版本、失败记录和报告队列 |

以下文件属于**接入方 App**，不是运行时强制规定的文件名：

- `hotfix.android.json`：构建配置，通过命令参数传入。文件名可以自行选择。
- `lib/main_hotfix.dart`：示例定制启动入口，负责加载补丁、启动业务、确认健康并检查更新。
  具体入口路径由 `entry` 指定；仅指定文件路径并不会自动完成原生宿主接入。
- `lib/hotfix/probe.dart`：可选的验收诊断文件，可用固定返回值或故障注入验证执行与回退。
  它不是补丁入口，也不是运行时必需文件；正式业务修复直接修改实际业务文件。

## 构建配置说明

配置在构建时读取，不是手机运行期间动态读取的远程配置。修改服务器地址、
入口或编译参数不会改变已安装 App；此类基线配置变更需要重新构建并分发安装包。

| 字段 | 含义与约束 |
| --- | --- |
| `project` | 相对配置文件所在目录的 App 工程路径；Git 工作流要求它是仓库根目录 |
| `entry` | `lib/` 下的定制 Dart 启动入口 |
| `platform` | 目标平台；`release-android` 要求 `android` |
| `appId` | 应用包名，必须与实际 APK 一致 |
| `release` | `版本名+构建号`，必须与 `pubspec.yaml` 和 APK 一致 |
| `patchScope` | `lib` 表示基线中实际编译到的现有业务 Dart 库；兼容性仍需检查 |
| `patchLibrary` | 旧单库模式的可选配置；多文件模式通常省略 |
| `androidFlavor` | 工程中已经定义的 Android flavor；统一 APK 入口要求显式填写 |
| `dartDefines` | 可选的字符串键值表，传给编译器；必须与业务实际需要的编译参数一致，禁止覆盖保留键 |
| `updateOrigin` | App 检查、下载及上报所用的服务 origin；留空不发起更新请求 |
| `allowDevelopmentHttp` | 默认不允许 HTTP；仅本地测试时显式开启，正式配置使用 HTTPS |

通用 Android 配置示例（需替换包名、版本、flavor 和域名，示例不是已部署服务）：

```json
{
  "project": ".",
  "entry": "lib/main_hotfix.dart",
  "platform": "android",
  "appId": "com.example.app",
  "release": "1.0.0+1",
  "patchScope": "lib",
  "androidFlavor": "production",
  "dartDefines": {},
  "updateOrigin": "https://patches.example.com",
  "allowDevelopmentHttp": false
}
```

## 本地地址与正式服务的区别

`127.0.0.1:18091` 只是本地测试地址，不是管理网站，也不是运行时内置的公共服务。
端口可配置，服务默认监听 `127.0.0.1:8080`；设置 `HOTFIX_PORT=18091` 才使用 18091。
服务必须实际启动才可访问。根路径不提供管理页面，API 见[服务说明](delivery/README.md#api)。

手机的 `127.0.0.1` 指手机自身，不指开发电脑。USB 验收可对**指定测试设备**建立
`adb -s DEVICE_SERIAL reverse tcp:18091 tcp:18091`，将手机该端口转发到电脑服务；
结束后用同一指定设备的 `reverse --remove tcp:18091` 移除。不要在正式 App 中依赖 USB 转发。

服务采用 Dart `HttpServer` 和启动时指定目录内的文件存储，保存签名清单、补丁字节码、
分发/撤回状态及结果报告；没有数据库、管理网页或业务数据接口。
正式使用需要部署可访问的 HTTPS 服务、保护发布令牌和私钥、设置容量与滥用防护，
并在构建基线前配置正式地址。开发 HTTP 配置不能直接作为正式配置发布。

## 阅读与验证范围

- 下文给出环境要求、构建/发布命令及安全限制；[服务说明](delivery/README.md)定义 API。
- [安全模型](SECURITY.md)说明信任边界、回放风险及未完成的生产安全工作。
- 具体接入方的包名、提交号、设备信息和验收产物应留在其自身记录中，不作为通用配置或前置条件。
- 文档中的路径、域名和提交 A/B 均为模板；不代表任意项目都已完成接入或验收。

## Detailed workflow

You edit normal Dart source and commit it. The CLI selects the changed source;
you do not write IR or copy a separate patched Dart file.

**Multi-file mode:** set `"patchScope": "lib"` (or omit `patchLibrary`) to
instrument the project's existing `lib/` libraries compiled into the baseline.
Git can then select changes to multiple existing Dart files, including parts,
without maintaining a per-file allowlist. Changed functions share one atomic
module table; IDs include library identity so same-name functions cannot collide.

This is still not unrestricted Dart hot reload. New/deleted/renamed files,
class/field layout changes, constructor or field initializer changes, incompatible
method signatures, native code, assets and dependencies require a new base app.
Even unrelated documentation changes are conservatively rejected by the Git gate.
Existing method bodies and supported new static helpers may change across files.
Unreachable files not compiled into the baseline are not retroactively patchable.
Keeping an explicit `patchLibrary` without `patchScope` preserves legacy single-file mode.

## Commands

### Integrated Android APK workflow

The `release-android` wrapper runs the normal Flutter/Gradle native build,
creates a clean Git baseline through `release-git`, packages its exact AOT and
matching custom Engine before Gradle signing, and verifies the signed APK.
It does not install, publish, switch branches, or create commits.

Prerequisites: Python 3 on macOS/Linux, the pinned Flutter/Dart/custom Engine
toolchain, resolved project dependencies, and an Android host already integrated
with the native patch store and hotfix entrypoint. This is not automatic
integration of an arbitrary stock Flutter application.

Set `DART_BIN`, `FLUTTER_SDK`, `GEN_SNAPSHOT`, `HOTFIX_PUBLIC_KEY_FILE`,
`ANDROID_BUILD_TOOLS` (directory containing `aapt` and `apksigner`), and an
appropriate `JAVA_HOME`. `DART_SDK_SOURCE` defaults to `work/upstream/dart-sdk`.
Keep the same checkout, dependencies and pinned toolchain for patch builds.
Do not run other builds concurrently in that checkout.

The committed config must include `androidFlavor`, `dartDefines`, and a `release`
matching `pubspec.yaml`. Configure `updateOrigin` before building A: HTTPS for
real deployments, or loopback HTTP plus explicit `allowDevelopmentHttp: true`
only for USB/local tests. The endpoint cannot be changed in an installed A by
editing the build machine's config.

```sh
# Clean committed A. Output must be ignored or outside the project.
sh tool/hotfix release-android /path/to/app/hotfix.android.json /path/to/app/build/release-A

# Distribute ONLY release-A/app.apk after verifying android-release.json exists.
# Normal code edits, tests, and a local commit B follow, in the same checkout.
sh tool/hotfix patch-android /path/to/app/build/release-A HEAD /path/to/app/build/patch-B /private/keys patch-B

# Test first. Publication remains an explicit action, not part of compilation.
sh tool/hotfix publish https://your-patch-service.example /path/to/app/build/patch-B/manifest.json /path/to/app/build/patch-B/patch.bytecode
```

Archive the entire `release-A` directory. `app.apk` is the hotfix-enabled package;
`native.apk` is the intermediate ordinary package, NOT the distribution target.
`baseline/` contains compiler inputs and Git provenance. `android-release.json`
is written last and records the APK digest, verified signing certificate,
application/version identity, exact native library hashes and baseline identity.
An interrupted output is not a completed release. If `baseline/project.json`
already contains valid Git provenance and AOT generation finished, a failed
packaging step can be retried with the same `release-android CONFIG OUTPUT
--resume-packaging` command. This verifies the clean Git commit, configuration,
generator and recorded source hashes first; it refuses completed archives.
Otherwise use a fresh output. Packaging removes non-arm64 directories only from
the generated Gradle strip outputs; no native source files are removed.
The wrapper restores the two replaced native intermediates, but default Gradle
output APKs may still contain the custom Engine: only use explicit archive paths.

`patch-android` verifies the archive then invokes the existing guarded
`patch-git` and signature checks. It does not bypass compatibility limits.
Signing defaults to a 24-hour **admission** window (`HOTFIX_MANIFEST_TTL_SECONDS`,
1..31536000). The phase-three loader exempts only its persisted last-known-good
patch from expiry at cold boot, while retaining signature, identity and digest
checks. Pending/unhealthy patches are still subject to expiry. Older baselines
retain their old behavior; loader changes
require a new base APK. Do not deploy broadly based solely on local acceptance.

Check the wrapper without SDK or device:
`python3 -B tool/android_release_check.py`.

### Release controls (matching loader/server required)

```sh
# Create a newly signed policy for the SAME immutable payload and patch ID.
# BASELINE is the archive's baseline/ directory, not its parent.
sh tool/hotfix policy BASELINE PATCH_DIR KEY_DIR NEW_POLICY_DIR 10
sh tool/hotfix publish ORIGIN NEW_POLICY_DIR/manifest.json NEW_POLICY_DIR/patch.bytecode

# Expand by signing a newer policy from the last published policy directory.
sh tool/hotfix policy BASELINE NEW_POLICY_DIR KEY_DIR FULL_POLICY_DIR 100

# Pause/resume new distribution. Does not disable installed patches.
sh tool/hotfix pause ORIGIN BASELINE_ID true
sh tool/hotfix pause ORIGIN BASELINE_ID false

# Permanent withdrawal: sign, then explicitly publish this directory.
sh tool/hotfix policy BASELINE FULL_POLICY_DIR KEY_DIR WITHDRAWAL_DIR withdraw
sh tool/hotfix publish ORIGIN WITHDRAWAL_DIR/manifest.json WITHDRAWAL_DIR/patch.bytecode
sh tool/hotfix stats ORIGIN
```

Publish/pause/stats require `HOTFIX_PUBLISH_TOKEN`; plain HTTP additionally
requires `HOTFIX_ALLOW_DEV_HTTP=true` and is for local tests only. Policy signing
stays on the build machine. The server cannot change signed percentages, payloads
or revocation flags. A policy update requires a newer signed `issuedAt` and the
same payload/identity; an acknowledged revocation cannot be undone for that ID.
The server keeps a signed withdrawal feed even when a newer release becomes the
latest. Withdrawal takes effect after an online post-health check and the next
cold boot, not immediately in an already running session. Offline clients cannot
receive a new withdrawal. A replayed revocation is safe and permanent, including
after its admission timestamp expires. Malformed/unsigned controls fail closed.

Grey rollout uses a private random salt persisted in the native store. The salt
never leaves the device; selection is stable for a baseline/patch pair. Increasing
the signed percentage includes the previous selection. Reducing a percentage or
pausing does not withdraw an already installed healthy patch.

Storage is namespaced by frozen baseline ID. Explicit module-load failures reject
the candidate immediately and try a distinct verified LKG. Two consecutive boots
without health acknowledgement blacklist that candidate; the following boot
selects LKG or bundled code. This is a startup health policy, not detection of
every later business-page error or post-health crash.

Downloads retry one interrupted request from scratch; only complete authenticated
bytes enter storage. Reports are persisted before sending, retried on post-health
checks/next startup, and removed only after server acknowledgement. Random event
IDs deduplicate retries across client/server restarts; they are not user or device
IDs. `stats` returns untrusted **event counts**, not unique users or an authoritative
success rate, and does not trigger automatic rollbacks.

Explicit limits: 128 queued reports per install (a full queue refuses new reports,
without blocking patch health); 10 MiB single-process server report log (507 stops
new ingestion); 64 signed withdrawals per baseline / 128 KiB feed. Deployments
need capacity monitoring/rotation or a transactional backend before exceeding
these limits. No infinite retry loop, management website or production deployment
is included. Keep external dependencies and the pinned toolchain unchanged.

Focused checks: `delivery_check.dart` exercises real HTTP interruption, bad
signatures/blobs/identity, durable report retry/dedup, pause/resume, rollout and
withdrawal; `lifecycle_check.dart [NATIVE_LIBRARY]` exercises admission vs healthy
expiry, incomplete-boot recovery and tamper rejection. Their module callbacks
are test callbacks; separate device evidence is required for Flutter execution.

### Low-level examples

Use the pinned toolchain environment described in
[the project example](examples/order_app/README.md). The project must be the Git
repository root. Keep output directories ignored (for example `build/`) or
outside the checkout. Resolve dependencies before building.

Example multi-file configuration:

```json
{
  "project": ".",
  "entry": "lib/main_hotfix.dart",
  "patchScope": "lib",
  "platform": "android",
  "appId": "your.application.id",
  "release": "1.0.0+1"
}
```

For application build flags, optionally add a `dartDefines` string map (for
example `{"APP_CHANNEL":"main64"}`) matching native packaging. Reserved
`dart.*`, `flutter.*` and `HOTFIX_*` keys cannot be overridden. These values
are frozen into the baseline recipe. Multi-library releases first verify that
unchanged source produces no patch, before the expensive native AOT step.

```sh
# At a clean, committed baseline A, using your hotfix config:
sh tool/hotfix release-git /path/to/app/hotfix.android.json /path/to/app/build/base-A

# Package and install this exact frozen AOT with the matching custom Engine.
# Native APK packaging/signing remains a separate step, not a stock Flutter build.

# Develop normally, test, and commit B in the SAME checkout.
# No branch switching or committing is performed by these tools.
sh tool/hotfix patch-git /path/to/app/build/base-A HEAD /path/to/app/build/patch-B

# Review/test before signing and publishing:
sh tool/hotfix sign /path/to/app/build/base-A /path/to/app/build/patch-B /private/keys patch-B
```

`REF` may be a commit, branch or tag, but must resolve to the current checkout's
HEAD. Dirty/untracked files, missing Git provenance, no changes, deleted or
symlinked patch sources, and out-of-scope changes fail closed. Diagnostics name
unsupported changed files. Build inputs are fingerprinted using the existing
baseline checks, including generated Dart plugin registration.

The baseline records `gitCommit`; patches record `git-provenance.json`. Git
provenance is local audit metadata, not a replacement for signed baseline IDs.
A `.git-pending` sibling marks interrupted/failed Git patch validation; signing
rejects that output. Use a fresh output directory after failure, do not remove
the marker to force publication. Baselines made with the older `release`
command cannot be retroactively assigned an arbitrary Git commit.

Dependencies and the pinned toolchain must remain fixed. This workflow does not
fetch commits, regenerate dependencies, handle monorepo subdirectories, migrate
existing installations, or prove all external path dependency content immutable.
Use a new base APK for changes outside the supported scope. An application
installed from a stock Flutter build cannot accept these patches.
Existing single-file baseline installations also need a new base APK before
using multi-file patches. Retaining more code increases baseline size and adds
dispatch checks; production performance and size must be measured separately.

## Checks

```sh
dart spikes/patch_ir_spike/tool/git_workflow_check.dart
dart --packages=work/upstream/dart-sdk/.dart_tool/package_config.json \
  spikes/patch_ir_spike/tool/project_cli_check.dart
dart --packages=work/upstream/dart-sdk/.dart_tool/package_config.json \
  spikes/patch_ir_spike/tool/multi_library_check.dart work/upstream/dart-sdk
```

2026-09-14: local disposable Git repository A → B passed real Android frozen
AOT generation, automatic patch selection, DBC3 compilation and signature verification. Safety checks
cover dirty/no-change/wrong-ref/missing-provenance/multiple-file/deletion cases.
This historical checkpoint covered compilation and signing, not device execution.

Multi-file checks: real host AOT → DBC3 → AOT dispatch verified two-library
same-name functions, circular imports, cross-library types and a new helper,
unchanged forwarding calls, instance-method callbacks, private mixins,
module withdrawal, enum-structure and field-layout rejection.
A separate Flutter Android Git A→B fixture changed pricing and repository Dart
files together: frozen AOT and a two-function bytecode patch both compiled.
A three-file variant also changed a Flutter page title and passed compilation
and signature verification. UI rendering of this multi-file variant on a device
was outside that fixture's compilation/signature check.
Single-file generic/async and relative-import/part regressions also passed.
The unchanged Flutter fixture was additionally verified to produce no patch,
guarding against false differences introduced by serialization and rebinding.
Source selection includes APIs referenced by the baseline business Kernel;
new references outside the retained interface still fail closed.
