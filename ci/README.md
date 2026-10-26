# 独立 Jenkins 热更新适配（默认不清理）

这里的脚本不修改 Jenkins 配置，不触发任务，也不修改 App 源码。
原 `flutter_distributor` 普通打包流程保持不变。需要另行将脚本接入专用热更新任务后才会执行。

`jenkins_entry.py` 提供实际的基础包构建上传及补丁构建上传入口，配置文件由 CI 节点私有目录提供。
任务检出完整 App SHA，在专用目录构建并保存归档；补丁只使用对应冻结归档，不运行依赖升级。
成功基础包会创建 `hotfix-base-` 前缀的独立 Git 标签，供现有 Git Parameter 插件列出候选。
选择后仍会核对本地归档、平台和服务端维护状态，不能用同名版本或已退役标签替代。

## Jenkins 使用流程

专用任务需要配置 App Git SCM，分支参数使用 Git Parameter 的 `PT_BRANCH`，
基础包参数使用 `PT_TAG`，过滤条件为 `hotfix-base-*`。任务禁止并发构建。

1. 构建基础包：`BUILD_MODE=baseline`，选择 `platform` 和 App 的 `BRANCH`。
   此时忽略 `BASELINE_ID`。成功后管理网站显示安装包，Mini 留存完整编译归档。
2. 提交修复：在同一 App 版本上提交允许范围内的 Dart 修改。
3. 构建补丁：`BUILD_MODE=patch`，选择修复分支，以及相同平台对应的 `BASELINE_ID` 标签。
   服务端有记录但 Mini 没有对应归档时会拒绝构建。
4. 构建成功后检查 Jenkins 的 `hotfix-result.json` 和管理网站的待发布补丁，再手动发布。
   上传步骤同时准备已签名撤回清单；构建任务不会自动向用户发布。

新基线要求 App 提交 `pubspec.lock`，Android 项目提交 Gradle wrapper。
依赖解析启用 `--enforce-lockfile`，避免构建机继承的镜像设置意外升级依赖。
节点初始化和环境检查由维护者完成，正常构建参数中无需 `CHECK_ONLY`。

## 当前状态

- 同一 App / 平台 / 渠道维护最近两个**成功上传的基线**，不是按版本字符串比较。
- 服务端 `HOTFIX_RETENTION_ENABLED` 默认关闭；本地删除也需要显式参数。
- 关闭时只登记和预览，不淘汰、不删除文件、不停止当前补丁分发。
- 历史记录不自动纳入；启用前需确认其渠道，再通过登记流程明确纳入并审查预览。
- OSS/CDN 适配程序已提供，但实际凭据及 CLI 尚未配置或验收；不能把模拟测试当作线上缓存已经失效。

## Mini 目录

选择一个独立的 CI 数据目录，不使用普通 Jenkins workspace、用户主目录或 SDK 目录。
运行 `ci_baselines.py allocate --root <专用目录>` 分配唯一 build 目录；它带 `.ci-owned.json` 标记。
在其 `project/` 子目录创建独立 Git worktree，完整基础包输出必须位于该 build 目录的 `archive/`。
所有新基线共享 `git-cache/` 中按远程地址区分的裸仓库，提交历史只存一份。
缓存更新持有文件锁；源码、依赖配置和编译输出仍各自隔离，不切换普通 App 工作区。
已有独立克隆继续兼容，不搬动已有冻结归档。缓存不自动清理，以免破坏保留中的 worktree。
Flutter、Dart 编译器和 Engine 使用节点专用工具目录及同一 Pub 缓存，不为每个基线复制工具链。
冻结后不要搬动目录。私钥、SDK、Engine 源码、共享依赖缓存均放在此目录外。

```text
CI 专用数据目录/
├── index.json
├── git-cache/   # 共享 Git 对象；不要手工删除或执行 worktree prune
└── builds/<随机 build ID>/
    ├── .ci-owned.json
    ├── project/     # 对应基线的稳定源码目录
    └── archive/     # 完整编译归档及成功标记
```

## 基础包步骤

1. 分配上述目录，检出已接入热更新的 App 提交；不运行 `pub upgrade`。
2. 使用固定工具版本和配套 Engine，通过现有 `release-android` / `release-ios` 构建。
3. 使用 `tool/upload_baseline.py` 上传 APK/IPA，必须收到成功登记回执。
4. 使用下列命令登记本地归档及服务器维护策略：

```sh
python3 ci/retention_client.py register \
  --origin https://updates.example.com \
  --root /path/to/dedicated-ci-data \
  --archive /path/to/dedicated-ci-data/builds/BUILD_ID/archive \
  --channel main64
```

上传凭据由 Jenkins Credentials 注入 `HOTFIX_UPLOAD_TOKEN`，不要在参数或日志中放令牌。
`channel` 必须来自选定基线的构建配置，不能把多个渠道统称为同一组。
只有本地成功标记、冻结基线身份和服务端成功记录一致才登记。
本命令默认不执行本地删除；失败构建、失败上传不进入这一步。

## 补丁步骤

通过 `status` 取得服务端状态，再用 `ci_baselines.py list` 与本地可用归档求交集。
没有归档的基线不能选，不能用同版本号的其他基础包代替。

```sh
python3 ci/retention_client.py patch \
  --origin https://updates.example.com \
  --root /path/to/dedicated-ci-data \
  --baseline-id BASELINE_ID -- /path/to/trusted-patch-and-upload-script
```

子命令得到环境变量 `HOTFIX_BASELINE_ARCHIVE`。该脚本负责在对应稳定源码目录检出修复提交，
使用冻结工具生成补丁、签名、上传补丁与撤回清单；不得自动发布。
适配器同时持有本地归档锁和服务端租约，每分钟续租；续租失败终止自己的子进程组。
任务结束释放租约，在其间不会因第三份基线到来而删除正在使用的归档。
Jenkins 应调用 `jenkins_entry.py --mode patch`，由它组合租约适配器与受控的实际编译上传子进程。
是否部署、执行成功以对应 Jenkins 任务及管理服务的回执为准。

## 清理必须双重启用

- 服务端由运维设置 `HOTFIX_RETENTION_ENABLED=true`，并提供经过真实验证的 `HOTFIX_RETIRE_EXECUTABLE`。
- CI 命令再显式增加 `--apply-local-retention`，才清理服务端已确认退役且未占用的本地目录。
- 两者目前均不启用。原有归档及安装包不会因为增加这些脚本而被删除。
- Mini 删除的是带归属标记的整个旧 build 目录；这属于不可恢复的本地清理，旧基线不能再生成补丁。
- 服务端退役先停止检查更新、编号及上传/发布；不强制回滚已生效或已下载的客户端补丁。

## 对象存储 / CDN 适配器契约

服务端仅允许调用已配置的绝对路径程序，不执行客户端传入的命令。
程序从 stdin 接收 `{"schemaVersion":1,"hashes":["64位摘要"]}`，只能处理配置中的专用
OSS bucket/prefix 和 CDN 路径；不得递归清理 bucket 或其他业务目录。
未被其他活动/历史基线引用的对象才会传给它。

只有源站删除及 CDN 刷新**实际完成**后，stdout 才能返回：

```json
{"originDeleted":true,"cdnPurged":true,"hashes":["与输入完全一致的摘要"]}
```

退出码为零或 CDN 仅受理任务都不算完成。程序必须幂等，重试已删除对象也可成功。
服务端在确认前保留 `cleanupStatus=pending`，网页会提示旧 CDN 地址可能仍可访问。
适配器不接收管理/上传 Token；OSS/CDN 凭据留在受限的服务端环境配置中。
阿里云适配器为 `delivery/hosted/retire_aliyun.py`，需要真实 ossutil、Alibaba Cloud CLI，
以及受限的 OSS 配置/CDN profile。程序额外要求 `HOTFIX_RETIRE_CONFIRM=true`，否则拒绝执行。
还需配置 `HOTFIX_RETIRE_OSSUTIL`、`HOTFIX_RETIRE_CDNCLI`、`HOTFIX_CDN_PROFILE`、
`HOTFIX_RETIRE_STATE`（服务端私有进度目录）。不要把现有仅支持上传的 Node 适配器当作 ossutil。
它仅删除精确摘要对象，不使用递归参数；持久保存 CDN task ID，后续重试查询状态，
只有所有任务为 Complete 才返回成功。使用前须配置最小权限并用专用测试对象实际验收。
接口依据：[RefreshObjectCaches](https://www.alibabacloud.com/help/en/cdn/developer-reference/api-cdn-2018-05-10-refreshobjectcaches)、
[DescribeRefreshTasks](https://www.alibabacloud.com/help/en/cdn/developer-reference/api-cdn-2018-05-10-describerefreshtasks)。

## 回归

```sh
python3 -B ci/ci_baselines_check.py
python3 -B ci/retention_client_check.py
python3 -B delivery/hosted/retire_aliyun_check.py
dart delivery/hosted/retention_policy_check.dart
dart delivery/hosted/baseline_registry_check.dart
dart spikes/patch_ir_spike/tool/delivery_check.dart
node --test console/web/src/baseline_list.test.js
```

检查使用临时目录/回环 HTTP，不调用真实 OSS/CDN，不删除现有归档，不操作手机。
