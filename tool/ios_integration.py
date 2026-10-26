"""Conservative, standard Swift Runner integration; custom delegates stay manual."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
from urllib.parse import urlsplit

from android_release import ROOT, read, require, run
from project_config import native_options, resolve_config

DELEGATE = '''import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  var hotfixEngine: FlutterEngine?
  override func application(_ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    guard let resolved = realpath(documents, nil) else { return false }
    defer { free(resolved) }
    guard psio_set_app_base(resolved) == 0 else { return false }
    let root = String(cString: resolved) + "/hotfix"
    let engine = FlutterEngine(name: "hotfix-runtime")
    guard engine.run(withEntrypoint: nil, libraryURI: nil, initialRoute: nil,
      entrypointArgs: [root + "/inbox/patch.bytecode", root + "/inbox/manifest.json", root + "/store"]) else { return false }
    GeneratedPluginRegistrant.register(with: engine)
    hotfixEngine = engine
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
'''

SCENE = '''import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene,
      let delegate = UIApplication.shared.delegate as? AppDelegate,
      let engine = delegate.hotfixEngine else { fatalError("Hotfix Engine not initialized") }
    window = UIWindow(windowScene: windowScene)
    window?.rootViewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    window?.makeKeyAndVisible()
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
'''


def plan(project, info, origin, allow_lan, dart_source, team, entry, validate_origin):
    config_file = project / 'hotfix.ios.json'
    if config_file.exists():
        config = read(config_file)
        require(config.get('platform') == 'ios' and (project / config['project']).resolve() == project,
                '已有 iOS 配置必须指向当前工程')
        require(not origin or config.get('updateOrigin') == origin, '不覆盖已有 iOS 服务地址')
        native_config = native_options(config)
        require(not team or (native_config.get('team') or resolve_config(config, project)['native']['team']) == team,
                '不覆盖已有签名 Team')
        require(not allow_lan or config.get('allowDevelopmentLan') is True, '已有配置需显式允许局域网开发测试')
        validate_origin(config['updateOrigin'], config.get('allowDevelopmentLan') is True)
        path = Path(config['entry'])
        require(path.parts[0] == 'lib' and '..' not in path.parts and (project / path).is_file(), '无效 iOS 入口')
        return {}, config
    if not team:
        team = resolve_config({'platform': 'ios'}, project)['native']['team']
    require(re.fullmatch(r'[A-Z0-9]{10}', team), '请先在 Xcode 配置签名团队，或指定 --ios-team')
    require(origin, 'iOS 真机需要 --origin；开发 HTTP 请使用 --dev-lan 和电脑局域网 IP')
    development = validate_origin(origin, allow_lan)
    require(not development or allow_lan, 'iOS 真机不能使用电脑 127.0.0.1，请指定 --dev-lan')
    delegate = project / 'ios/Runner/AppDelegate.swift'
    text = delegate.read_text()
    standard = '''import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
'''
    require(text.strip() == standard.strip(), '自定义 iOS AppDelegate 不自动覆盖，请按手动接入说明合并')
    scene_file = project / 'ios/Runner/SceneDelegate.swift'
    require(re.sub(r'\s+', '', scene_file.read_text()) == 'importFlutterimportUIKitclassSceneDelegate:FlutterSceneDelegate{}',
            '自定义 SceneDelegate 不自动覆盖，请手动合并')
    require(re.search(r'\b(?:void|Future<void>)\s+main\(\s*\)', (project / 'lib/main.dart').read_text()), '需要无参数 main')
    pbx = project / 'ios/Runner.xcodeproj/project.pbxproj'
    require('psio_' not in pbx.read_text(), '已有 native hotfix 接入，不重复修改')
    identifiers = set(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = "?([A-Za-z0-9_.]+)"?;', pbx.read_text()))
    identifiers = {value for value in identifiers if not value.endswith('.RunnerTests')}
    require(len(identifiers) == 1, '不能唯一确定 iOS 包名，请手动接入')
    require('patch_ir_spike' not in info['dependencies'] and '_fe_analyzer_shared' not in info['overrides'],
            '已有 runtime 依赖配置，请手动合并 iOS 接入')
    spec = (project / 'pubspec.yaml').read_text()
    require(re.search(r'^dependencies:\s*(?:#.*)?$', spec, re.M), '需要独立 dependencies 节')
    runtime = json.dumps(os.path.relpath(ROOT / 'spikes/patch_ir_spike', project))
    shared = json.dumps(os.path.relpath(Path(dart_source) / 'pkg/_fe_analyzer_shared', project))
    spec = re.sub(r'^(dependencies:[ \t]*(?:#.*)?)$', lambda m: m[0] + '\n  patch_ir_spike:\n    path: ' + runtime, spec, count=1, flags=re.M)
    override = '\n  _fe_analyzer_shared:\n    path: ' + shared
    if re.search(r'^dependency_overrides:', spec, re.M):
        require(re.search(r'^dependency_overrides:[ \t]*(?:#.*)?$', spec, re.M), '不支持内联 overrides')
        spec = re.sub(r'^(dependency_overrides:[ \t]*(?:#.*)?)$', lambda m: m[0] + override, spec, count=1, flags=re.M)
    else:
        spec += '\ndependency_overrides:' + override + '\n'
    bridge = project / 'ios/Runner/Runner-Bridging-Header.h'
    header = bridge.read_text() + '\nint psio_set_app_base(const char *path);\n'
    plist = project / 'ios/Runner/Info.plist'
    values = plistlib.loads(plist.read_bytes())
    configurations = values.get('UIApplicationSceneManifest', {}).get('UISceneConfigurations', {}).get('UIWindowSceneSessionRoleApplication', [])
    require(len(configurations) == 1 and configurations[0].get('UISceneDelegateClassName') == '$(PRODUCT_MODULE_NAME).SceneDelegate',
            '需要标准单窗口 Scene 配置，请手动合并')
    configurations[0].pop('UISceneStoryboardFile', None)
    values.pop('UIMainStoryboardFile', None)
    if development:
        require('NSAppTransportSecurity' not in values, '已有 ATS 策略需手动合并')
        values['NSLocalNetworkUsageDescription'] = 'Connect to the development hotfix server.'
        # Flutter's Dart network policy reads exception domains, not the local
        # networking flag. Scope its HTTP exception to this explicit test host.
        values['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True, 'NSExceptionDomains': {
            urlsplit(origin).hostname: {'NSIncludesSubdomains': False, 'NSExceptionAllowsInsecureHTTPLoads': True}}}
    with tempfile.TemporaryDirectory() as directory:
        copy = Path(directory) / 'Runner.xcodeproj'
        copy.mkdir()
        shutil.copyfile(pbx, copy / 'project.pbxproj')
        run(['ruby', ROOT / 'tool/ios_integrate.rb', copy, ROOT / 'native/patch_store_io.c', team])
        settings = (copy / 'project.pbxproj').read_text()
    config = {'project': '.', 'entry': 'lib/main_hotfix.dart', 'patchScope': 'lib', 'platform': 'ios',
              'dartDefines': {}, 'updateOrigin': origin, 'allowDevelopmentHttp': development,
              **({'allowDevelopmentLan': True} if development else {})}
    new = {project / 'lib/main_hotfix.dart': entry, config_file: json.dumps(config, indent=2) + '\n'}
    for path in new:
        require(not path.exists(), f'不覆盖已有文件: {path}')
    return {project / 'pubspec.yaml': spec, delegate: DELEGATE, scene_file: SCENE, bridge: header, pbx: settings,
            plist: plistlib.dumps(values).decode(), **new}, config
