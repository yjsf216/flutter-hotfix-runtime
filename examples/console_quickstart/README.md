# 从干净源码验证首次使用

完成[工具链准备](../../TOOLCHAIN_SETUP.md)并通过 doctor 后，在 Runtime 根目录执行：

```sh
python3 -B tool/first_use_check.py
```

工具路径来自环境变量，也可用 --flutter-sdk、--android-sdk、--java-home、--dart-sdk-source、
--gen-snapshot 参数指定。已有初始化工程可用 `--toolchain-profile /path/to/app/.hotfix/local.json`
复用其安装路径，脚本只读取其中的工具环境，不复用该 App 的源码、密钥、归档或服务数据。

脚本创建全新的 Runtime Git clone 和 Flutter Android 工程，使用空的 PUB_CACHE 与
GRADLE_USER_HOME，按五步文档实际运行 doctor、init、项目内 console 入口，测试页面，
通过管理 API 构建 APK、生成签名补丁、发布、下载核对哈希、查询空报告、撤回。
过程中不会安装 App 或使用手机，端口由本机随机分配，结束后停止它启动的服务。

结果、日志、测试密钥和归档保留在忽略的 work/first-use-* 目录。
固定的 Flutter/Dart/Android SDK、JDK 和已编译定制 Engine 作为显式安装的工具链复用；
这不是从空机器重新编译整套 Engine 的测试。首次运行会下载 Pub/Gradle 依赖，需要网络。

脚本复用宿主 Android SDK 已接受的许可，不替用户接受新条款。
本机代理可通过标准环境变量配置；它不会关闭证书校验或更改全局代理。

手动操作请看[五步使用流程](../../GETTING_STARTED.md)。
