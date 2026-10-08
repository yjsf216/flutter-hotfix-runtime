"""Small, project-local front end. Existing compiler/packager remain the authority."""
import argparse
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

from android_release import ROOT, digest, head, read, require, run

ENTRY = '''import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:patch_ir_spike/dbc3_dispatch.dart';
import 'main.dart' as app;

Future<void> main(List<String> args) async {
  if (!Platform.isAndroid || args.length != 3) {
    throw StateError('Android hotfix host requires three private paths');
  }
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final patch = await bootSignedModule(args);
  await Future<void>.sync(app.main);
  await binding.waitUntilFirstFrameRasterized;
  // Replace this minimal checkpoint with the app's real startup validation.
  if (patch != null && !commitModuleHealth(patch)) {
    throw StateError('Hotfix health commit failed');
  }
  await checkUpdatesAfterHealth(patch);
}
'''
ARGS_METHOD = ''' {
    override fun getDartEntrypointArgs(): List<String> {
        val root = java.io.File(filesDir.canonicalFile, "hotfix")
        return listOf(
            java.io.File(root, "inbox/patch.bytecode").path,
            java.io.File(root, "inbox/manifest.json").path,
            java.io.File(root, "store").path,
        )
    }
}
'''
NETWORK = '''<network-security-config>
    <base-config cleartextTrafficPermitted="false" />
    <domain-config cleartextTrafficPermitted="true"><domain includeSubdomains="false">127.0.0.1</domain></domain-config>
</network-security-config>
'''


def save(path, value):
    """Local profiles/state contain no secret values; still keep them private."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if temporary.exists():
                temporary.unlink()


def ask(label, default=''):
    if not sys.stdin.isatty():
        require(bool(default), f'{label} 未配置；请使用 init 参数或交互终端')
        return default
    return input(f'{label} [{default}]: ').strip() or default


def project_root():
    project = Path.cwd().resolve()
    require((project / 'pubspec.yaml').is_file(), '请在 Flutter App 仓库根目录运行')
    require((project / '.git').is_dir() and not (project / '.git').is_symlink(),
            '需要独立 Git 仓库；简化入口暂不支持 linked worktree')
    require(Path(run(['git', 'rev-parse', '--show-toplevel'], project, True).strip()).resolve() == project,
            '请在 App Git 仓库根目录运行')
    require(not (project / '.hotfix').is_symlink(), '.hotfix 不能是软链接')
    return project


def local_http(origin):
    require(isinstance(origin, str) and origin == origin.strip() and not any(ord(c) < 32 for c in origin), '无效服务地址')
    url = urlsplit(origin)
    require(url.hostname and '@' not in url.netloc and
            url.path in ('', '/') and not url.query and not url.fragment,
            '更新地址必须是没有路径、认证信息或查询参数的 origin')
    require(url.scheme == 'https' or url.scheme == 'http' and url.hostname == '127.0.0.1',
            '正式地址必须 HTTPS；简化入口只允许 127.0.0.1 的测试 HTTP')
    _ = url.port  # Validate malformed ports before writing anything.
    return url.scheme == 'http'


def tools_environment(args, previous):
    saved = previous.get('environment', {})
    flutter_default = saved.get('FLUTTER_SDK', os.environ.get('FLUTTER_SDK', ''))
    if not flutter_default and shutil.which('flutter'):
        flutter_default = str(Path(shutil.which('flutter')).resolve().parent.parent)
    flutter = Path(args.flutter_sdk or ask('Flutter 3.41.9 SDK 路径', flutter_default)).expanduser().resolve()
    sdk = Path(args.android_sdk or ask('Android SDK 路径', saved.get('ANDROID_SDK_ROOT',
        os.environ.get('ANDROID_SDK_ROOT', os.environ.get('ANDROID_HOME', ''))))).expanduser().resolve()
    java = Path(args.java_home or ask('JDK 路径', saved.get('JAVA_HOME', os.environ.get('JAVA_HOME', '')))).expanduser().resolve()
    builds = sorted((sdk / 'build-tools').glob('*'),
                    key=lambda p: [int(n) for n in re.findall(r'\d+', p.name)])
    build_tools = saved.get('ANDROID_BUILD_TOOLS') or os.environ.get('ANDROID_BUILD_TOOLS')
    if not build_tools:
        build_tools = next((str(p) for p in reversed(builds) if (p / 'apksigner').is_file()), '')
    generator = saved.get('GEN_SNAPSHOT', os.environ.get('GEN_SNAPSHOT', str(ROOT /
        'work/upstream/flutter-engine-ddm/engine/src/out/hotfix_android_release_arm64/artifacts_arm64/gen_snapshot_arm64')))
    result = {'FLUTTER_SDK': str(flutter), 'DART_BIN': str(flutter / 'bin/cache/dart-sdk/bin/dart'),
              'ANDROID_SDK_ROOT': str(sdk), 'JAVA_HOME': str(java),
              'ANDROID_BUILD_TOOLS': build_tools, 'GEN_SNAPSHOT': generator,
              'DART_SDK_SOURCE': str(ROOT / 'work/upstream/dart-sdk')}
    validate_tools(result)
    return result


def validate_tools(env):
    require(shutil.which('openssl'), '缺少 OpenSSL，无法生成或签署补丁')
    for name, path in {
        'Flutter': Path(env['FLUTTER_SDK']) / 'bin/flutter', 'Dart': Path(env['DART_BIN']),
        'JDK': Path(env['JAVA_HOME']) / 'bin/java',
        'aapt': Path(env['ANDROID_BUILD_TOOLS']) / 'aapt',
        'apksigner': Path(env['ANDROID_BUILD_TOOLS']) / 'apksigner',
        '定制 gen_snapshot': Path(env['GEN_SNAPSHOT']),
        '定制 Engine': Path(env['GEN_SNAPSHOT']).parent.parent / 'lib.stripped/libflutter.so',
        'Dart 源码依赖': Path(env['DART_SDK_SOURCE']) / '.dart_tool/package_config.json',
    }.items():
        require(path.is_file(), f'缺少 {name}: {path}。请先完成 engine/README.md 的工具链准备')
    version = Path(env['FLUTTER_SDK']) / 'bin/internal/engine.version'
    require(version.read_text().strip() == '42d3d75a56efe1a2e9902f52dc8006099c45d937', '需要固定 Flutter 3.41.9 工具链')


def tool_stamp():
    # Conservative: even tool-test changes require deliberately retaining the old
    # tool checkout. Never silently build a patch with different runtime sources.
    files = [ROOT / 'tool/hotfix', ROOT / 'native/CMakeLists.txt', ROOT / 'spikes/patch_ir_spike/pubspec.yaml']
    files += list((ROOT / 'tool').glob('*.py')) + list((ROOT / 'tool').glob('*.dart'))
    files += list((ROOT / 'spikes/patch_ir_spike/lib').rglob('*.dart'))
    files += list((ROOT / 'spikes/patch_ir_spike/tool').glob('*.dart'))
    files += list((ROOT / 'native').glob('*.c')) + list((ROOT / 'native').glob('*.h'))
    return hashlib.sha256(json.dumps({str(p.relative_to(ROOT)): digest(p) for p in sorted(files)}, sort_keys=True).encode()).hexdigest()


def app_info(project, env):
    return json.loads(run([env['DART_BIN'], '--packages=' + env['DART_SDK_SOURCE'] + '/.dart_tool/package_config.json',
                           ROOT / 'tool/app_info.dart', project / 'pubspec.yaml'], capture=True, env={**os.environ, **env}))


def integration_plan(project, info, origin):
    """Only a recognizable plain FlutterActivity template is edited automatically."""
    config_file = project / 'hotfix.android.json'
    if config_file.exists():
        config = read(config_file)
        require(config['platform'] == 'android' and (project / config['project']).resolve() == project,
                '已有配置必须指向当前 Android App')
        require(not origin or config.get('updateOrigin') == origin, '不自动覆盖已有服务地址；请单独修改配置并构建新基线')
        local_http(config.get('updateOrigin', ''))
        require(isinstance(config.get('androidFlavor'), str) and re.fullmatch(r'[a-z][A-Za-z0-9]*', config['androidFlavor']),
                '已有配置需要明确的 androidFlavor，请按手动教程补齐')
        require(isinstance(config.get('entry'), str) and bool(config['entry']), '已有配置缺少 entry')
        entry = Path(config['entry'])
        require(bool(entry.parts) and entry.parts[0] == 'lib' and '..' not in entry.parts and (project / entry).is_file(), '已有定制入口不存在')
        return {}, config
    origin = origin or ask('补丁服务 origin（默认仅本机测试）', 'http://127.0.0.1:18091')
    development = local_http(origin)
    gradles = [p for p in [project / 'android/app/build.gradle.kts', project / 'android/app/build.gradle'] if p.is_file()]
    activities = list((project / 'android/app/src/main/kotlin').rglob('MainActivity.kt'))
    require(len(gradles) == 1 and len(activities) == 1, '无法唯一识别 Gradle/MainActivity；请按 GETTING_STARTED.md 手动接入后重新 init')
    gradle, activity = gradles[0], activities[0]
    gradle_text, activity_text = gradle.read_text(), activity.read_text()
    require(not any(word in gradle_text for word in ['externalNativeBuild', 'productFlavors', 'flavorDimensions', 'applicationIdSuffix', 'hotfix.gradle']),
            '已有 flavor/CMake/包名后缀配置，需要手动合并；未修改文件')
    pattern = r'(?m)^[ \t]*class\s+MainActivity\s*:\s*FlutterActivity\s*\(\s*\)\s*(?:\{\s*\})?\s*\Z'
    require('import io.flutter.embedding.android.FlutterActivity' in activity_text, '无法识别标准 FlutterActivity')
    require(re.search(pattern, activity_text), 'MainActivity 有自定义逻辑；不自动覆盖，请手动接入')
    app_ids = re.findall(r'\bapplicationId\s*(?:=\s*)?[\x27\x22]([\w.]+)[\x27\x22]', gradle_text)
    require(len(app_ids) == 1, '无法确定 applicationId')
    require(re.search(r'\b(?:void|Future<void>)\s+main\(\s*\)', (project / 'lib/main.dart').read_text()),
            '示例只适配无参数 main；请手动适配入口')
    require('patch_ir_spike' not in info['dependencies'] and '_fe_analyzer_shared' not in info['overrides'],
            '已有相关依赖/覆盖配置，请手动合并以避免覆盖')
    pubspec = project / 'pubspec.yaml'
    spec = pubspec.read_text()
    require(re.search(r'^dependencies:\s*(?:#.*)?$', spec, re.M), '不支持内联 dependencies，请手动接入')
    runtime_path = json.dumps(os.path.relpath(ROOT / 'spikes/patch_ir_spike', project))
    shared_path = json.dumps(os.path.relpath(ROOT / 'work/upstream/dart-sdk/pkg/_fe_analyzer_shared', project))
    spec = re.sub(r'^(dependencies:[ \t]*(?:#.*)?)$',
                  lambda m: m[0] + '\n  patch_ir_spike:\n    path: ' + runtime_path, spec, count=1, flags=re.M)
    override = '\n  _fe_analyzer_shared:\n    path: ' + shared_path
    if re.search(r'^dependency_overrides:', spec, re.M):
        require(re.search(r'^dependency_overrides:[ \t]*(?:#.*)?$', spec, re.M), '不支持内联 dependency_overrides')
        spec = re.sub(r'^(dependency_overrides:[ \t]*(?:#.*)?)$', lambda m: m[0] + override, spec, count=1, flags=re.M)
    else:
        spec += '\ndependency_overrides:' + override + '\n'
    cmake_path = os.path.relpath(ROOT / 'native/CMakeLists.txt', gradle.parent).replace('\\', '\\\\').replace("'", "\\'")
    native = f'''// Generated hotfix integration; preserve the app's signing configuration.
android {{
    flavorDimensions 'hotfixDistribution'
    productFlavors {{ hotfix {{ dimension 'hotfixDistribution'; ndk {{ abiFilters 'arm64-v8a' }} }} }}
    if (project.hasProperty('hotfixRuntime')) {{
        externalNativeBuild {{ cmake {{ path file('{cmake_path}'); version '3.22.1' }} }}
    }}
}}
'''
    manifest = project / 'android/app/src/main/AndroidManifest.xml'
    manifest_text = manifest.read_text()
    require('xmlns:android="http://schemas.android.com/apk/res/android"' in manifest_text, '无法识别 Manifest 命名空间')
    require(manifest_text.count('<application') == 1, '无法识别单一 Application，请手动接入')
    app_name = re.findall(r'android:name="([^"]+)"', manifest_text.split('<application', 1)[1].split('>', 1)[0])
    require(not app_name or app_name == ['${applicationName}'], '自定义 Application 需人工检查 Engine 启动路径')
    if development:
        require('networkSecurityConfig' not in manifest_text, '已有网络策略，请手动合并测试配置')
    if 'android.permission.INTERNET' not in manifest_text:
        manifest_text = re.sub(r'(<manifest\b[^>]*>)', r'\1\n    <uses-permission android:name="android.permission.INTERNET" />', manifest_text, count=1)
    config = {'project': '.', 'entry': 'lib/main_hotfix.dart', 'patchScope': 'lib', 'platform': 'android',
              'appId': app_ids[0], 'androidFlavor': 'hotfix', 'dartDefines': {},
              'updateOrigin': origin, 'allowDevelopmentHttp': development}
    plan = {pubspec: spec, activity: re.sub(pattern, 'class MainActivity : FlutterActivity()' + ARGS_METHOD, activity_text),
            gradle: gradle_text + ('\napply(from = "hotfix.gradle")\n' if gradle.suffix == '.kts' else "\napply from: 'hotfix.gradle'\n"),
            manifest: manifest_text}
    new = {project / 'lib/main_hotfix.dart': ENTRY, gradle.parent / 'hotfix.gradle': native,
           config_file: json.dumps(config, indent=2) + '\n'}
    if development:
        new[project / 'android/app/src/hotfix/AndroidManifest.xml'] = '''<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:networkSecurityConfig="@xml/hotfix_network_security" />
</manifest>
'''
        new[project / 'android/app/src/hotfix/res/xml/hotfix_network_security.xml'] = NETWORK
    for path in new:
        require(not path.exists(), f'不覆盖已有文件: {path}')
    return {**plan, **new}, config


def initialize(project, args):
    local = project / '.hotfix'
    profile_file = local / 'local.json'
    require(not profile_file.is_symlink(), '本地配置不能是软链接')
    require(not local.exists() or profile_file.is_file(), '已有 .hotfix 目录不是本入口管理的配置，拒绝覆盖')
    previous = read(profile_file) if profile_file.exists() else {}
    if previous:
        require(previous.get('schemaVersion') == 1 and previous.get('project') == str(project),
                '本地配置不属于当前路径；请恢复原工程路径或在新目录重新接入，归档不会自动迁移')
    env = tools_environment(args, previous)
    info = app_info(project, env)
    require(isinstance(info['version'], str) and re.fullmatch(r'[0-9A-Za-z.+_-]+', info['version']), 'pubspec.yaml 必须有明确的 version')
    plan, config = integration_plan(project, info, args.origin)
    key_default = previous.get('keys') or (str(Path(os.environ['HOTFIX_PUBLIC_KEY_FILE']).parent)
        if os.environ.get('HOTFIX_PUBLIC_KEY_FILE') else str(local / 'keys'))
    keys = Path(args.keys or ask('补丁密钥目录（不存在时生成测试密钥）', key_default)).expanduser().resolve()
    require(not keys.exists() or (keys / 'private.pem').is_file() and (keys / 'public-key.txt').is_file(),
            '密钥目录已存在但不完整，拒绝覆盖')
    for path in plan:
        require(not path.is_symlink() and all(not p.is_symlink() for p in path.parents if p != project.parent),
                f'不改写软链接路径: {path}')
    print('将复用已有接入配置' if not plan else '将生成/修改:\n' + '\n'.join(str(p.relative_to(project)) for p in plan))
    print('模式：本机 HTTP 测试' if local_http(config['updateOrigin']) else '模式：HTTPS（不会自动部署服务器）')
    if args.dry_run:
        print('预览结束，未写入文件、生成密钥或解析依赖。')
        return
    require(not run(['git', 'ls-files', '.hotfix'], project, True).strip(), '.hotfix 中存在已跟踪文件，请先处理，不能把密钥放入版本控制')
    # Use local Git excludes so adopting an existing baseline does not add a
    # non-Dart source change. No global Git or shell configuration is modified.
    exclude = project / '.git/info/exclude'
    require(not exclude.is_symlink() and not exclude.parent.is_symlink(), 'Git exclude 不能是软链接')
    exclude.parent.mkdir(exist_ok=True)
    existing = exclude.read_text() if exclude.exists() else ''
    if '/.hotfix/' not in existing.splitlines():
        exclude.write_text(existing.rstrip('\n') + '\n/.hotfix/\n')
    hidden = subprocess.run(['git', 'check-ignore', '-q', '--no-index', '--', '.hotfix/local.json'], cwd=project)
    require(hidden.returncode == 0, '项目规则取消了 .hotfix 的忽略，请先修正；未写入密钥或源码')
    if keys == project or project in keys.parents:
        relative = str(keys.relative_to(project))
        hidden_keys = subprocess.run(['git', 'check-ignore', '-q', '--no-index', '--', relative + '/.secret-probe'], cwd=project)
        tracked_key = run(['git', 'ls-files', '--', relative + '/private.pem'], project, True)
        require(hidden_keys.returncode == 0 and not tracked_key.strip(), 'App 内密钥目录必须整体忽略且私钥不能已被跟踪；建议使用仓库外目录')
    local.mkdir(exist_ok=True, mode=0o700)
    if plan:
        backup = local / 'backups' / secrets.token_hex(6)
        originals = {p: p.read_bytes() if p.exists() else None for p in plan}
        for path, value in originals.items():
            if value is not None:
                destination = backup / path.relative_to(project)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(value)
        print('原文件备份:', backup)
        for path, contents in plan.items():
            require((path.read_bytes() if path.exists() else None) == originals[path], f'文件在初始化期间被修改: {path}')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
    env['HOTFIX_PUBLIC_KEY_FILE'] = str(keys / 'public-key.txt')
    profile = {'schemaVersion': 1, 'project': str(project), 'keys': str(keys), 'environment': env, 'ready': False}
    save(profile_file, profile)
    launcher = local / 'run'
    require(not launcher.is_symlink(), '本地入口不能是软链接')
    launcher.write_text('#!/bin/sh\nset -eu\ncd -- "$(dirname -- "$0")/.."\nexec python3 -B ' + shlex.quote(str(ROOT / 'tool/app_cli.py')) + ' "$@"\n')
    launcher.chmod(0o700)
    environment = {**os.environ, **env}
    run([env['DART_BIN'], 'pub', 'get'], ROOT / 'spikes/patch_ir_spike', env=environment)
    if not keys.exists():
        keys.mkdir(parents=True, mode=0o700)
        run([env['DART_BIN'], ROOT / 'spikes/patch_ir_spike/tool/signature_check.dart', 'keygen', keys], env=environment)
        (keys / 'private.pem').chmod(0o600)
    run([Path(env['FLUTTER_SDK']) / 'bin/flutter', 'pub', 'get'], project, env=environment)
    profile['ready'] = True
    save(profile_file, profile)
    print('初始化完成。审查并提交 App 接入改动后，运行 ./.hotfix/run build。')
    print('日常命令：./.hotfix/run build | patch | publish | serve | status')
    print('首次使用仍需验收启动与业务健康检查；不会自动安装 App 或发布补丁。')


def invoke(profile, *args, extra=None):
    run(['sh', ROOT / 'tool/hotfix', *args], env={**os.environ, **profile['environment'], **(extra or {})})


def baseline_for(project, state):
    require(state.get('baseline'), '尚无成功基线，请先 build；已有低层归档可继续使用 release-android/patch-android')
    base = Path(state['baseline'])
    receipt = read(base / 'android-release.json')
    metadata = read(base / 'baseline/project.json')
    require(Path(metadata['project']).resolve() == project and receipt['baselineId'] ==
            read(base / 'baseline/release/release.json')['baselineId'], '基线不属于当前工程')
    return base, receipt


def perform(project, action, yes=False):
    local = project / '.hotfix'
    profile = read(local / 'local.json')
    require(profile.get('schemaVersion') == 1 and profile.get('ready') and profile.get('project') == str(project),
            '本地配置未完成或工程已移动，请重新 init')
    state_file = local / 'state.json'
    state = read(state_file) if state_file.exists() else {}
    if action == 'status':
        print(json.dumps({'baseline': state.get('baseline'), 'patch': state.get('patch')}, indent=2))
        return
    if action in ('build', 'patch'):
        # Clear implicit publication selection before a new attempt, including
        # preflight failures, so a failed build cannot publish yesterday's patch.
        state.pop('patch', None)
        save(state_file, state)
        validate_tools(profile['environment'])
        stamp = tool_stamp()
        commit = head(project)
        info = app_info(project, profile['environment'])
        require(isinstance(info['version'], str) and re.fullmatch(r'[0-9A-Za-z.+_-]+', info['version']), '无效 App 版本')
        suffix = commit[:12] + '-' + secrets.token_hex(4)
        if action == 'build':
            config = read(project / 'hotfix.android.json')
            config.update(project=str(project), release=info['version'])
            generated = local / 'configs' / (suffix + '.json')
            save(generated, config)
            output = local / 'releases' / (info['version'] + '-' + suffix)
            invoke(profile, 'release-android', generated, output)
            require((output / 'android-release.json').is_file(), '构建未产生完成标志')
            require(tool_stamp() == stamp, '工具源码在构建期间发生变化，请使用新的输出重试')
            state['baseline'] = str(output)
            state['toolStamp'] = stamp
            save(state_file, state)
            print('版本构建完成；安装包:', output / 'app.apk')
        else:
            base, receipt = baseline_for(project, state)
            require(state.get('toolStamp') == stamp, '工具/运行时源码与基线构建时不同，请恢复原工具版本或构建新基线')
            require(receipt['release'] == info['version'], '当前 App 版本与上次基线不同；请切回对应修复分支或 build 新基线')
            output = local / 'patches' / suffix
            invoke(profile, 'patch-android', base, 'HEAD', output, profile['keys'], 'patch-' + suffix)
            require(tool_stamp() == stamp, '工具源码在补丁构建期间发生变化，不选择该产物发布')
            manifest = read(output / 'manifest.json')['manifest']
            require(manifest['baselineId'] == receipt['baselineId'], '补丁基线不匹配')
            state['patch'] = {'path': str(output), 'baseline': str(base),
                              'manifestSha256': digest(output / 'manifest.json'),
                              'artifactSha256': digest(output / 'patch.bytecode')}
            save(state_file, state)
            print('补丁已生成，尚未发布:', output)
            print('在测试环境验收后，运行 ./.hotfix/run publish。')
        return
    if action == 'serve':
        config = read(project / 'hotfix.android.json')
        require(local_http(config['updateOrigin']), 'serve 只启动本机 HTTP 测试服务；HTTPS 请按 delivery/README.md 部署')
        token_file = local / 'publish-token'
        require(not token_file.is_symlink(), '令牌文件不能是软链接')
        if not token_file.exists():
            with token_file.open('x') as stream:
                os.chmod(token_file, 0o600)
                stream.write(secrets.token_hex(24))
        token = token_file.read_text().strip()
        require(len(token) >= 24, '测试发布令牌无效')
        port = urlsplit(config['updateOrigin']).port or 80
        print(f'启动本机测试服务 127.0.0.1:{port}；另开终端生成/发布补丁，Ctrl+C 停止。', flush=True)
        invoke(profile, 'serve', local / 'server', profile['environment']['HOTFIX_PUBLIC_KEY_FILE'],
               extra={'HOTFIX_BIND': '127.0.0.1', 'HOTFIX_PORT': str(port), 'HOTFIX_PUBLISH_TOKEN': token})
        return
    candidate = state.get('patch')
    require(candidate, '没有待发布补丁，请先成功运行 patch')
    patch = Path(candidate['path'])
    require(digest(patch / 'manifest.json') == candidate['manifestSha256'] and
            digest(patch / 'patch.bytecode') == candidate['artifactSha256'], '待发布产物已被修改，请重新生成')
    base, receipt = baseline_for(project, {'baseline': candidate['baseline']})
    manifest = read(patch / 'manifest.json')['manifest']
    require(manifest['baselineId'] == receipt['baselineId'], '发布目标与补丁不匹配')
    origin = read(base / 'baseline/project.json')['updateOrigin']
    development = local_http(origin)
    print(f"发布目标: {origin}\nApp: {receipt['appId']} {receipt['release']}\n补丁: {manifest['patchId']}\n基线: {receipt['baselineId']}", flush=True)
    if not yes:
        require(sys.stdin.isatty(), '非交互发布必须显式使用 publish --yes')
        if input('确认已验收并发布？[y/N] ').strip().lower() != 'y':
            print('已取消，未上传。')
            return
    token = os.environ.get('HOTFIX_PUBLISH_TOKEN', '')
    if not token and development and (local / 'publish-token').is_file():
        token = (local / 'publish-token').read_text().strip()
    if not token and sys.stdin.isatty():
        token = getpass.getpass('发布令牌（不保存）: ')
    require(len(token) >= 24, '需要发布令牌；本机测试请先 serve，正式环境设置 HOTFIX_PUBLISH_TOKEN')
    invoke(profile, 'publish', origin, patch / 'manifest.json', patch / 'patch.bytecode',
           extra={'HOTFIX_PUBLISH_TOKEN': token, 'HOTFIX_ALLOW_DEV_HTTP': str(development).lower()})
    print('服务端已接收；用户仍需下载并在下一次冷启动生效。')


def main():
    parser = argparse.ArgumentParser(description='在 App 根目录使用的简化入口，不自动提交/安装/推送')
    parser.add_argument('action', choices=['init', 'build', 'patch', 'publish', 'serve', 'status'])
    for name in ['flutter-sdk', 'android-sdk', 'java-home', 'keys', 'origin']:
        parser.add_argument('--' + name)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--yes', action='store_true')
    args = parser.parse_args()
    if args.action != 'init' and (args.dry_run or any([args.flutter_sdk, args.android_sdk, args.java_home, args.keys, args.origin])):
        parser.error('路径、origin 和 --dry-run 参数只适用于 init')
    if args.yes and args.action != 'publish':
        parser.error('--yes 只适用于 publish')
    project = project_root()
    with open(project / '.git/hotfix-simple.lock', 'a') as lock:
        # Server deliberately holds no build lock; it runs alongside patching.
        if args.action not in ('serve', 'status'):
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == 'init':
            initialize(project, args)
        else:
            perform(project, args.action, args.yes)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit('ERROR: ' + str(error))
    except KeyboardInterrupt:
        sys.exit('已中止。未完成输出不可分发；已完成的基线和补丁仍保留。')
