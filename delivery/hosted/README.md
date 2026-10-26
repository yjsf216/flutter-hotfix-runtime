# 服务端管理部署（测试版）

两份基线保留策略及 Mini 归档适配见 [CI 保留策略](../../ci/README.md)。默认关闭，
仅新增流程显式登记的基线参与；现有上传、App 检查及普通打包保持原行为。
实际对象删除/CDN 刷新适配器尚未接通，不能在没有验收的情况下启用。

本机生成并签名补丁，通过管理服务上传；服务端上传 OSS、核对 CDN 内容，
管理页面再确认发布。服务端只需要 Dart 服务及 ossutil，无需 Flutter、Xcode、
业务 Git 仓库或 Dart 编译器源码。现有本机控制台仍负责本地构建。

## 已实现与未验证

- `/v1/uploads` 接收已签名的清单及补丁，上传身份与发布身份分离；重复上传幂等。
- 上传、发布均校验签名及内容；配置 OSS 后，CDN 内容校验失败不会开放更新。
- 管理身份查询待发布列表，通过 `/v1/activate` 发布或启用已上传的签名撤回清单。
- 独立页面为 `console/static/hosted.html`，包含基线、补丁发布和结果查询。
- 本地真实 HTTP 回归覆盖上传不发布、权限隔离、损坏内容、存储失败、显式发布和已有客户端生命周期。
- 2026-10-19 已在 Linux x64 测试环境验证 HTTPS 管理入口、鉴权、上传不发布、
  单独发布、签名撤回，以及真实 OSS 上传和 CDN 哈希校验；8 MiB 上传容量通过。
- 此轮为服务端/API 验收，未重新安装手机或验证新的公网基线。测试环境不等于生产认证。

## 本机上传

### 基础包

完成本地 `build` 后，用命令输出的完整发行归档目录登记基础版本：

```sh
python3 tool/upload_baseline.py https://updates-test.example.com/hotfix \
  /path/to/completed-release \
  --source-branch release/1.2.3 --source-commit FULL_SOURCE_COMMIT
```

上传凭据仍使用 `HOTFIX_UPLOAD_TOKEN`。工具先核对构建完成标记、安装包哈希及
Git 来源，再以 4 MiB 分块提交。服务端组装、校验并上传对象存储，核对 CDN 后
才登记为可见基础版本。基础版本不依赖补丁记录；页面显示版本、平台、来源提交、
实际构建提交、基线 ID 和安装包下载。iOS 包仍受原签名与设备授权限制。

支持重复执行相同上传；同一基线不能覆盖成另一安装包或另一来源。完整编译归档
仍须保留在构建机并备份，网站上的 APK/IPA 不能替代生成补丁所需的冻结归档。
单安装包上限 1 GiB，同时最多 20 个未完成上传；失败上传暂存保留以便重试，
管理员需监控存储空间并按基线清理废弃暂存，不能直接删除正在上传的目录。

基础版本按 `registeredAt`（上传并校验完成的时间）倒序显示，按 App / 平台分别标记
“最新上传”；它不代表最高版本或已通过发布验收。页面时间使用浏览器本地时区。

管理凭据可通过 `POST /v1/baselines/BASELINE_ID/delete` 删除列表记录，通过
`POST /v1/baselines/BASELINE_ID/restore` 恢复；请求体为空或 `{}`。这些操作幂等，
仅保存／移除独立删除标记，不改原始基线元数据、不删 OSS/CDN 文件或构建机归档，
也不停止已有补丁分发。上传凭据不能删除或恢复；重复上传不会自动恢复已删除记录。
默认 `GET /v1/baselines` 隐藏删除记录，`?includeDeleted=1` 返回包含 `deletedAt`
的完整列表，对应页面“显示已删除”。物理存储清理和补丁撤回仍是独立操作。

### 补丁

新基础包可在构建配置中设置 `patchNumberingOrigin` 为管理 API 的 HTTPS 根地址
（支持与 `updateOrigin` 相同的路径前缀）。生成补丁前设置服务签发的
`HOTFIX_UPLOAD_TOKEN`，编译完成后的签名步骤会请求 `/v1/patch-numbers`。

编号按精确基线（因此也区分平台）递增；同一 `patchId` 重试返回原编号。
分配失败就停止签名，不降级为本机计数。失败构建或撤回不会回收编号，允许有空号。
服务端必须单进程运行并备份 `*.numbers` 台账，不能删除台账后从头编号。

新编号保存在 v2 签名清单的 `patchNumber` 中，原始 `patchId` 不变；管理页同时显示。
新运行时接受旧 v1 清单但不显示编号，旧基础包不支持 v2，需安装接入后的新基础包。
未配置 `patchNumberingOrigin` 的既有本地工作流继续生成无编号 v1 清单。

App 在启动健康检查成功后读取 `currentPatchNumber`。下载、仅加载或仅发布不会
提前变更显示；失败回退使用实际健康运行补丁的编号，回到基础包时为 `null`。
业务层只将它用作版本展示后缀，不应替换安装包版本、接口版本或版本升级判断。

在本机安全配置 `HOTFIX_UPLOAD_TOKEN`，然后执行：

```sh
python3 tool/upload_patch.py https://updates-test.example.com /path/to/signed-patch
```

目录必须包含 `manifest.json` 和 `patch.bytecode`。命令仅上传，不发布。
仅本地开发可加 `--dev-loopback`，且只接受 `http://127.0.0.1:PORT`。
返回结果不确定时可重试原包；不得通过更换补丁 ID 掩盖网络超时。
撤回清单由本机既有 `hotfix policy` 命令签名，连同对应字节码同样上传。
撤回清单有效期仍会检查，过期需在本机重新签名。

补丁列表按 `uploadedAt`（首次上传完成时间）倒序排列；重试上传不会刷新时间。
旧记录没有时间台账时使用现存清单文件的修改时间，可能是旧版服务最后一次重传时间，
不是签名清单的 `issuedAt`。网页按浏览器本地时区显示。

管理身份可调用 `POST /v1/uploads/BASELINE_ID/PATCH_ID/delete` 或 `/restore`，
请求体为空或 `{}`。删除仅隐藏记录，可在“显示已删除”中恢复；已发布且未撤回的补丁
拒绝删除（409），需先完成签名撤回。删除不改 CDN 文件、撤回策略、运行结果或编号台账，
也不能让已安装的补丁自动回滚。已删除记录不能发布，重传不会恢复；
恢复不自动发布，也不能撤销已生效的撤回。默认列表隐藏删除记录，
`GET /v1/uploads?includeDeleted=1` 返回包含 `deletedAt` 的完整记录。

## 运行配置

在本目录执行 `dart pub get`，再运行 `dart run server.dart STORAGE PUBLIC_KEY_FILE`。
也可在目标 Linux 架构编译：`dart compile exe server.dart -o hotfix-service`。
公共验签代码从本仓库复用，构建时保留相对目录结构。

服务端通过受限权限环境文件注入下列配置，禁止提交真实值：

| 名称 | 用途 |
|---|---|
| `HOTFIX_PUBLISH_TOKEN` | 管理查询、发布和撤回凭据 |
| `HOTFIX_UPLOAD_TOKEN` | 单独的上传凭据，不能发布 |
| `HOTFIX_OSSUTIL` | 服务器本地 ossutil 可执行文件绝对路径 |
| `HOTFIX_OSS_CONFIG` | 服务器本地 ossutil 凭据文件路径 |
| `HOTFIX_OSS_BUCKET` | 已授权的测试 bucket |
| `HOTFIX_OSS_PREFIX` | 专用目录，例如 `flutter-hotfix/test` |
| `HOTFIX_CDN_BLOB_BASE` | 对应上述目录的 HTTPS 下载目录，末尾带 `/` |
| `HOTFIX_BIND` / `HOTFIX_PORT` | 默认 `127.0.0.1:8080`，置于反向代理之后 |

对象键为 `PREFIX/v1/blobs/ARTIFACT_SHA256`。不设置 public-read ACL；
bucket 与 CDN 回源权限由部署配置提供。服务端不持有补丁签名私钥。
已有 `ali-oss` 的 Node.js 环境可以使用 `oss_upload.cjs` 适配器替代 ossutil，
需在服务环境中提供正确的 `PATH` 和 `NODE_PATH`；它只支持本项目的不可覆盖补丁上传。
线上入口 `server.dart` 要求 OSS/CDN 配置齐全，不能悄悄退回本地文件存储。

静态页面可挂载到 `/hotfix/`，目录入口使用 `hosted.html`；其相对
`v1/*` 请求由代理去掉 `/hotfix/` 前缀转到服务端。静态 `assets/` 同时部署。
管理入口必须经 HTTPS，限制请求体、超时、速率及内部监听端口访问。
存储目录独立于版本目录，单进程运行并备份；当前事件日志和清单列表有容量上限。

复用既有 Node.js 测试入口时，`node_proxy.cjs` 提供固定 loopback 代理，挂载在
body parser 之前；只转发明确的热更新 API，不转发业务 Cookie。代理不实现补丁业务。
服务端资源限制应单独作用于热更新进程；验证环境使用 256 MiB 内存上限和 50% CPU 配额。
若使用 systemd `RestrictAddressFamilies`，保留 `AF_NETLINK`：存储 SDK 的网卡查询需要它，
否则即使 HTTPS 地址和凭据正确，上传也可能失败。可同时使用空 `CapabilityBoundingSet`。

新基线的 `updateOrigin` 支持 HTTPS 安全路径前缀，例如 `https://updates.example.com/hotfix`；
动态 API 相对于该前缀请求。`artifactBase` 可单独指定固定 HTTPS CDN 目录，必须以 `/`
结尾，下载内容仍受签名、大小及哈希校验。省略时继续从 API 的 `/v1/blobs/HASH` 下载。
动态 API 不缓存；不能用 302 跳转代替，客户端下载禁用重定向。
修改已冻结的更新地址需要发行新基线包。

## 部署验收

发布前验证上传成功、CDN 字节哈希一致、未发布时 App 无更新；网页确认后再验证
下载、冷启动健康及签名撤回。检查独立服务重启后的持久状态，并保留旧版本目录。
服务端发布和真实设备验收完成前，不把本地协议测试标记为公网部署成功。
