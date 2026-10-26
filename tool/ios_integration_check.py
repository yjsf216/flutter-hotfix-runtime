"""Conservative iOS integration gates, without device/SDK/account access."""
import json
from pathlib import Path
import tempfile
import unittest
import plistlib
import subprocess
from unittest.mock import patch

import app_cli
import ios_integration as ios


class IOSIntegrationCheck(unittest.TestCase):
    def test_native_graph_is_idempotent_and_plist_override_is_runner_scoped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / 'Runner.xcodeproj'
            native = root / 'patch_store_io.c'
            native.write_text('// fixture')
            subprocess.run(['ruby', '-rxcodeproj', '-e', '''
p = Xcodeproj::Project.new(ARGV[0])
%w[Runner Plugin].each do |name|
  t = p.new_target(:application, name, :ios, '13.0')
  t.build_configurations.each do |c|
    c.build_settings['INFOPLIST_FILE'] = name + '/Info.plist'
    c.build_settings['DEVELOPMENT_TEAM'] = 'ORIGINAL01'
  end
end
p.save
''', str(project)], check=True)
            command = ['ruby', str(Path(__file__).with_name('ios_integrate.rb')),
                       str(project), str(native), 'ABCDEFGHIJ', '--preserve-settings']
            subprocess.run(command, check=True)
            before = (project / 'project.pbxproj').read_bytes()
            subprocess.run(command, check=True)
            self.assertEqual((project / 'project.pbxproj').read_bytes(), before)
            subprocess.run(['ruby', '-rxcodeproj', '-e', '''
p = Xcodeproj::Project.open(ARGV[0])
r = p.targets.find { |t| t.name == 'Runner' }
abort unless r.source_build_phase.files.length == 1
r.build_configurations.each do |c|
  abort unless c.build_settings['INFOPLIST_FILE'] == '$(HOTFIX_RUNNER_INFO_PLIST)'
  abort unless c.build_settings['HOTFIX_RUNNER_INFO_PLIST'] == 'Runner/Info.plist'
  abort unless c.build_settings['DEVELOPMENT_TEAM'] == 'ORIGINAL01'
end
p.targets.find { |t| t.name == 'Plugin' }.build_configurations.each do |c|
  abort unless c.build_settings['INFOPLIST_FILE'] == 'Plugin/Info.plist'
  abort if c.build_settings.key?('HOTFIX_RUNNER_INFO_PLIST')
end
''', str(project)], check=True)

    def test_standard_scene_and_exact_development_host_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            runner = project / 'ios/Runner'
            runner.mkdir(parents=True)
            (runner / 'AppDelegate.swift').write_text('''import Flutter
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
''')
            (runner / 'SceneDelegate.swift').write_text('import Flutter\nimport UIKit\n\nclass SceneDelegate: FlutterSceneDelegate {\n\n}\n')
            (runner / 'Runner-Bridging-Header.h').write_text('#import "GeneratedPluginRegistrant.h"\n')
            (project / 'lib').mkdir()
            (project / 'lib/main.dart').write_text('void main() {}')
            (project / 'pubspec.yaml').write_text('name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n')
            pbx = project / 'ios/Runner.xcodeproj/project.pbxproj'
            pbx.parent.mkdir()
            pbx.write_text('PRODUCT_BUNDLE_IDENTIFIER = com.example.demo;')
            scene = {'UISceneDelegateClassName': '$(PRODUCT_MODULE_NAME).SceneDelegate', 'UISceneStoryboardFile': 'Main'}
            values = {'UIApplicationSceneManifest': {'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [scene]}}}
            (runner / 'Info.plist').write_bytes(plistlib.dumps(values))
            info = {'dependencies': ['flutter'], 'overrides': []}
            with patch.object(ios, 'run'):
                plan, config = ios.plan(project, info, 'http://192.168.1.100:18091', True,
                                        '/explicit/sdk', 'ABCDEFGHIJ', app_cli.ENTRY, app_cli.local_http)
            generated = plistlib.loads(plan[runner / 'Info.plist'].encode())
            self.assertIn('UIApplicationSceneManifest', generated)
            self.assertNotIn('NSAllowsArbitraryLoads', generated['NSAppTransportSecurity'])
            domains = generated['NSAppTransportSecurity']['NSExceptionDomains']
            self.assertEqual(set(domains), {'192.168.1.100'})
            self.assertFalse(domains['192.168.1.100']['NSIncludesSubdomains'])
            self.assertIn('UIWindow(windowScene:', plan[runner / 'SceneDelegate.swift'])
            self.assertNotIn('UIWindow(frame:', plan[runner / 'AppDelegate.swift'])
            self.assertEqual(config['platform'], 'ios')
            self.assertFalse((project / 'hotfix.ios.json').exists())

    def test_existing_config_not_replaced_and_conflicts_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            (project / 'lib').mkdir()
            (project / 'lib/main_hotfix.dart').write_text('// existing custom entry')
            config = {'platform': 'ios', 'project': '.', 'entry': 'lib/main_hotfix.dart',
                      'iosTeam': 'ABCDEFGHIJ', 'updateOrigin': 'https://updates.example.invalid'}
            (project / 'hotfix.ios.json').write_text(json.dumps(config))
            plan, found = ios.plan(project, {}, None, False, '', None, '', app_cli.local_http)
            self.assertEqual(plan, {})
            self.assertEqual(found, config)
            with self.assertRaisesRegex(ValueError, '签名 Team'):
                ios.plan(project, {}, None, False, '', 'OTHERTEAM1', '', app_cli.local_http)
            with self.assertRaisesRegex(ValueError, '服务地址'):
                ios.plan(project, {}, 'https://other.invalid', False, '', None, '', app_cli.local_http)
            config['entry'] = 'lib/../private.dart'
            (project / 'hotfix.ios.json').write_text(json.dumps(config))
            with self.assertRaisesRegex(ValueError, '入口'):
                ios.plan(project, {}, None, False, '', None, '', app_cli.local_http)

    def test_new_plan_refuses_custom_delegate_and_device_loopback_before_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            delegate = project / 'ios/Runner/AppDelegate.swift'
            delegate.parent.mkdir(parents=True)
            delegate.write_text('// user customized delegate')
            with self.assertRaisesRegex(ValueError, 'AppDelegate'):
                ios.plan(project, {}, 'https://updates.example.invalid', False, '', 'ABCDEFGHIJ', '', app_cli.local_http)
            with self.assertRaisesRegex(ValueError, '127.0.0.1'):
                ios.plan(project, {}, 'http://127.0.0.1:18091', False, '', 'ABCDEFGHIJ', '', app_cli.local_http)
            self.assertEqual(delegate.read_text(), '// user customized delegate')
            self.assertFalse((project / '.hotfix').exists())


if __name__ == '__main__':
    unittest.main()
