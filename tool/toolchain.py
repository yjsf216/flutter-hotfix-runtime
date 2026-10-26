"""Read-only toolchain discovery and installation diagnostics; no SDK downloads."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import engine_bundle

ROOT = Path(__file__).resolve().parent.parent
ENGINE_REVISION = '42d3d75a56efe1a2e9902f52dc8006099c45d937'
DART_REVISION = 'c70f78e7d682c158c15ca0c26c729b3ccb932284'
PATH_OPTIONS = {'flutter_sdk': 'FLUTTER_SDK', 'android_sdk': 'ANDROID_SDK_ROOT',
                'java_home': 'JAVA_HOME', 'dart_sdk_source': 'DART_SDK_SOURCE',
                'gen_snapshot': 'GEN_SNAPSHOT'}


def profile_directory(project, target=None):
    root = Path(project) / '.hotfix'
    target = target or os.environ.get('HOTFIX_ACTIVE_PLATFORM')
    if target and target not in ('android', 'ios'):
        raise ValueError('Unsupported platform')
    if root.is_symlink():
        raise ValueError('.hotfix cannot be a symlink')
    profile = root / 'local.json'
    if profile.is_symlink():
        raise ValueError('Profile cannot be a symlink')
    if target:
        current = json.loads(profile.read_text()).get('platform', 'android') if profile.is_file() else 'android'
        if current != target:
            root = root / target
    if root.is_symlink() or (root / 'local.json').is_symlink():
        raise ValueError('Platform profile cannot be a symlink')
    return root


def command(args):
    try:
        result = subprocess.run([str(x) for x in args], text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=15,
                                env={**os.environ, 'GIT_OPTIONAL_LOCKS': '0'})
        return result.stdout.strip() if result.returncode == 0 else ''
    except (OSError, subprocess.TimeoutExpired):
        return ''


def discover(args, saved=None):
    saved = saved or {}
    values = {}
    for option, variable in PATH_OPTIONS.items():
        values[variable] = getattr(args, option, None) or saved.get(variable) or os.environ.get(variable, '')
    if not values['FLUTTER_SDK'] and shutil.which('flutter'):
        values['FLUTTER_SDK'] = str(Path(shutil.which('flutter')).resolve().parent.parent)
    if not values['ANDROID_SDK_ROOT']:
        values['ANDROID_SDK_ROOT'] = os.environ.get('ANDROID_HOME', '') or next(
            (str(p) for p in (Path.home() / 'Library/Android/sdk', Path.home() / 'Android/sdk') if p.is_dir()), '')
    if not values['JAVA_HOME'] and Path('/usr/libexec/java_home').is_file():
        values['JAVA_HOME'] = command(['/usr/libexec/java_home', '-v', '17'])
    values['DART_SDK_SOURCE'] = values['DART_SDK_SOURCE'] or str(ROOT / 'work/upstream/dart-sdk')
    target = getattr(args, 'platform', None) or saved.get('HOTFIX_TARGET_PLATFORM', 'android')
    abi = getattr(args, 'abi', None) or saved.get('HOTFIX_TARGET_ABI', 'arm64')
    bundle = None if getattr(args, 'gen_snapshot', None) else engine_bundle.from_project(
        getattr(args, 'project', None) or Path.cwd(), target, abi)
    if bundle:
        values.update(bundle)
    generator_cpu = 'armv7' if abi == 'arm' else 'arm64'
    values['GEN_SNAPSHOT'] = values['GEN_SNAPSHOT'] or str(ROOT /
        f'work/upstream/flutter-engine-ddm/engine/src/out/hotfix_{target}_release_{abi}/artifacts_arm64/gen_snapshot_{generator_cpu}')
    values = {k: str(Path(v).expanduser().resolve()) if v else '' for k, v in values.items()
              if k != 'HOTFIX_TARGET_ABI'}
    values['HOTFIX_TARGET_ABI'] = abi
    values['DART_BIN'] = str(Path(values['FLUTTER_SDK']) / 'bin/cache/dart-sdk/bin/dart') if values['FLUTTER_SDK'] else ''
    if target == 'ios':
        values['HOTFIX_TARGET_PLATFORM'] = target
    builds = sorted((Path(values['ANDROID_SDK_ROOT']) / 'build-tools').glob('*'),
                    key=lambda p: [int(n) for n in re.findall(r'\d+', p.name)]) if values['ANDROID_SDK_ROOT'] else []
    selected = saved.get('ANDROID_BUILD_TOOLS') or os.environ.get('ANDROID_BUILD_TOOLS', '')
    values['ANDROID_BUILD_TOOLS'] = str(Path(selected).expanduser().resolve()) if selected else next(
        (str(p) for p in reversed(builds) if (p / 'apksigner').is_file()), '')
    return values


def inspect(env):
    ios = env.get('HOTFIX_TARGET_PLATFORM') == 'ios'
    checks = []
    def check(name, ok, detail, hint):
        checks.append({'name': name, 'ok': bool(ok), 'detail': detail, 'hint': '' if ok else hint})
    if env.get('HOTFIX_ENGINE_MANIFEST'):
        try:
            bundle = engine_bundle.verify(env['HOTFIX_ENGINE_MANIFEST'], 'ios' if ios else 'android',
                                          env.get('HOTFIX_TARGET_ABI', 'arm64'))
            valid = Path(env.get('GEN_SNAPSHOT', '')).resolve() == Path(bundle['GEN_SNAPSHOT'])
            check('engine-bundle', valid, env['HOTFIX_ENGINE_MANIFEST'], 'Engine/generator must match the verified bundle')
        except (ValueError, OSError, KeyError) as error:
            check('engine-bundle', False, str(error), 'Re-fetch the pinned runtime package; never bypass artifact verification')
    check('host', platform.system() == 'Darwin' and platform.machine() == 'arm64',
          platform.system() + '/' + platform.machine(), '当前完整安装引导验收环境为 macOS Apple Silicon。')
    check('python', sys.version_info >= (3, 10), platform.python_version(), '安装 Python 3.10 或更高版本。')
    for binary in ('git', 'openssl'):
        found = shutil.which(binary)
        check(binary, found, found or '未找到', '安装 ' + binary + ' 并加入 PATH。')
    flutter = Path(env.get('FLUTTER_SDK') or '/nonexistent-hotfix-sdk')
    sdk = Path(env.get('ANDROID_SDK_ROOT') or '/nonexistent-hotfix-android')
    dart = Path(env.get('DART_SDK_SOURCE') or '/nonexistent-hotfix-source')
    generator = Path(env.get('GEN_SNAPSHOT') or '/nonexistent-hotfix-generator')
    build = generator.parent.parent
    version = flutter / 'bin/internal/engine.version'
    actual = version.read_text().strip() if version.is_file() else ''
    check('flutter-version', actual == ENGINE_REVISION, actual or '缺少 engine.version',
          '安装固定 Flutter 3.41.9，并使用 --flutter-sdk 指向它；不要修改其他项目的 FVM SDK。')
    files = {
        'flutter': (flutter / 'bin/flutter', True, '设置 --flutter-sdk /path/to/flutter-3.41.9。'),
        'dart': (Path(env.get('DART_BIN') or '/nonexistent-hotfix-dart'), True, '运行固定 SDK 的 flutter --version 完成 SDK 缓存准备。'),
        'flutter-platform': (flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill', False,
                             '运行固定 SDK 的 flutter precache --android。'),
        'aapt': (Path(env.get('ANDROID_BUILD_TOOLS') or '/nonexistent-hotfix-build-tools') / 'aapt', True,
                 '用 sdkmanager 安装 build-tools;36.1.0，或设置 ANDROID_BUILD_TOOLS 指向已安装版本。'),
        'apksigner': (Path(env.get('ANDROID_BUILD_TOOLS') or '/nonexistent-hotfix-build-tools') / 'apksigner', True,
                      '安装包含 apksigner 的 Android build-tools。'),
        'android-platform': (sdk / 'platforms/android-36/android.jar', False, '用 sdkmanager 安装 platforms;android-36。'),
        'android-ndk': (sdk / 'ndk/28.2.13676358/source.properties', False, '用 sdkmanager 安装 ndk;28.2.13676358。'),
        'cmake': (sdk / 'cmake/3.22.1/bin/cmake', True, '用 sdkmanager 安装 cmake;3.22.1。'),
        'gen-snapshot': (generator, True, '按 TOOLCHAIN_SETUP.md 构建定制 Android DDM Engine，再设置 --gen-snapshot。'),
        'ddm-engine': (build / 'lib.stripped/libflutter.so', False, 'gen_snapshot 与 libflutter.so 必须来自同一 Android arm64 DDM 输出目录。'),
        'dart-packages': (dart / '.dart_tool/package_config.json', False, '按 TOOLCHAIN_SETUP.md 同步固定 Dart 源码依赖并生成 package_config。'),
        'console-ui': (ROOT / 'console/static/index.html', False, '重新获取完整源码；仅前端维护者需在 console/web 执行 npm ci && npm run build。'),
    }
    for name, (path, executable, hint) in files.items():
        if ios and name in ('aapt', 'apksigner', 'android-platform', 'android-ndk', 'cmake', 'ddm-engine'):
            continue
        check(name, path.is_file() and (not executable or os.access(path, os.X_OK)), str(path), hint)
    java = Path(env.get('JAVA_HOME') or '/nonexistent-hotfix-jdk') / 'bin/java'
    java_version = command([java, '-version']) if java.is_file() else ''
    if not ios:
        check('jdk', bool(re.search(r'version "17[.\"]', java_version)), java_version.splitlines()[0] if java_version else str(java),
              '安装 JDK 17 并设置 --java-home；其他 JDK 需自行确认与 App 的 AGP 兼容。')
    else:
        check('ios-engine', (build / 'Flutter.framework/Flutter').is_file(), str(build / 'Flutter.framework'), '按 engine/build_ios_ddm.sh 构建 iOS Release DDM Engine。')
        check('xcode', command(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path']), 'iphoneos SDK', '安装并选择完整 Xcode。')
        check('xcodeproj', command(['ruby', '-rxcodeproj', '-e', 'puts Xcodeproj::VERSION']), 'Ruby xcodeproj', '安装 xcodeproj Ruby gem，用于安全编辑 Runner 构建设置。')
    revision = command(['git', '-C', dart, 'rev-parse', 'HEAD']) if (dart / '.git').exists() else ''
    check('dart-revision', revision == DART_REVISION, revision or '未找到 Dart Git checkout',
          '使用固定 Dart 提交 ' + DART_REVISION + '；设置 --dart-sdk-source。')
    args = build / 'args.gn'
    text = args.read_text() if args.is_file() else ''
    expected = {'target_os': '"ios"' if ios else '"android"', 'target_cpu': '"' + env.get('HOTFIX_TARGET_ABI', 'arm64') + '"', 'flutter_runtime_mode': '"release"',
                'dart_dynamic_modules': 'true', 'dart_version': '"' + DART_REVISION + '"'}
    correct = all(re.search(r'(?m)^' + key + r'\s*=\s*' + re.escape(value) + r'\s*$', text) for key, value in expected.items())
    check('ddm-configuration', correct, str(args), '需要 Android / arm64 / release / DDM=true 及固定 Dart 的 args.gn；普通 Flutter Engine 不适用。')
    required = ('kernel', 'front_end', 'dart2bytecode', 'dynamic_modules', '_fe_analyzer_shared')
    present = all((dart / 'pkg' / name / 'lib').is_dir() for name in required)
    check('dart-sources', present, str(dart / 'pkg'), '固定 Dart 源码必须包含：' + ', '.join(required))
    # The checked-in Dart runtime pubspec uses this canonical ignored path.
    binding = ROOT / 'work/upstream/dart-sdk'
    compatible = not (binding.exists() or binding.is_symlink()) or binding.resolve() == dart.resolve()
    check('runtime-sdk-binding', compatible, str(binding),
          '本 Runtime checkout 已绑定其他 Dart 源码。使用独立 Runtime clone；不会覆盖或重定向已有目录。')
    return checks


def bind_runtime_sdk(env):
    source = Path(env['DART_SDK_SOURCE']).resolve()
    destination = ROOT / 'work/upstream/dart-sdk'
    if destination.exists() or destination.is_symlink():
        if destination.resolve() != source:
            raise ValueError('Runtime 已绑定其他 Dart 源码，拒绝替换：' + str(destination))
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.symlink_to(source, target_is_directory=True)


def main():
    parser = argparse.ArgumentParser(description='只读检查固定工具链，汇总缺项并给出安装步骤')
    parser.add_argument('--platform', choices=['android', 'ios'])
    parser.add_argument('--abi', choices=['arm', 'arm64'])
    for option in PATH_OPTIONS:
        parser.add_argument('--' + option.replace('_', '-'))
    parser.add_argument('--project', type=Path, default=Path.cwd())
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--guide', action='store_true')
    args = parser.parse_args()
    profile = profile_directory(args.project, args.platform) / 'local.json'
    try:
        saved = json.loads(profile.read_text()).get('environment', {}) if profile.is_file() else {}
        env = discover(args, saved)
        checks = inspect(env)
    except (OSError, ValueError) as error:
        parser.exit(1, 'ERROR: ' + str(error) + '\n')
    ready = all(c['ok'] for c in checks)
    report = {'ready': ready, 'environment': env, 'checks': checks,
              'guide': str(ROOT / 'TOOLCHAIN_SETUP.md')}
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        for c in checks:
            print(('OK   ' if c['ok'] else 'MISS ') + c['name'] + ': ' + c['detail'])
            if not c['ok']:
                print('     ' + c['hint'])
        print('\n' + ('工具链检查通过。下一步：hotfix init。' if ready else '请补齐上述缺项后重新检查。'))
        print('安装指南：' + report['guide'])
        if args.guide:
            print('顺序：基础工具 → Flutter 3.41.9 → Android SDK/JDK → 固定 Dart 源码 → 定制 DDM Engine → doctor → init → console。')
            print('本命令不安装软件、不接受 SDK 许可、不修改项目；patch_runtime 0.2.0 起可从 Pub 解析目录使用配套 Engine。')
    return 0 if ready else 1


if __name__ == '__main__':
    sys.exit(main())
