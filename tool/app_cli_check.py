"""Local safety/orchestration tests; no SDK builds, network or device access."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import app_cli as app


class AppCliCheck(unittest.TestCase):
    def test_tool_stamp_ignores_checks_but_freezes_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / 'spikes/patch_ir_spike/lib/runtime.dart'
            runtime.parent.mkdir(parents=True)
            runtime.write_text('baseline runtime')
            checks = root / 'spikes/patch_ir_spike/tool/new_check.dart'
            checks.parent.mkdir(parents=True)
            checks.write_text('test v1')
            signer = checks.parent / 'signature_check.dart'
            signer.write_text('signer v1')
            with patch.object(app, 'ROOT', root), patch.object(app, 'digest', side_effect=lambda p: p.read_text() if p.exists() else ''):
                original = app.tool_stamp()
                checks.write_text('test v2')
                self.assertEqual(app.tool_stamp(), original)
                signer.write_text('signer v2')
                self.assertNotEqual(app.tool_stamp(), original)
                signer.write_text('signer v1')
                runtime.write_text('updated runtime')
                self.assertNotEqual(app.tool_stamp(), original)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.activity = self.root / 'android/app/src/main/kotlin/example/MainActivity.kt'
        self.gradle = self.root / 'android/app/build.gradle.kts'
        self.put('pubspec.yaml', 'name: demo\nversion: 1.0.0+1\ndependencies:\n  flutter:\n    sdk: flutter\n')
        self.put('lib/main.dart', 'void main() {}\n')
        self.put(self.activity.relative_to(self.root), 'package example\nimport io.flutter.embedding.android.FlutterActivity\nclass MainActivity : FlutterActivity()\n')
        self.put(self.gradle.relative_to(self.root), 'android {\n defaultConfig { applicationId = "com.example.demo" }\n}\n')
        self.put('android/app/src/main/AndroidManifest.xml', '<manifest xmlns:android="http://schemas.android.com/apk/res/android"><application android:name="${applicationName}" /></manifest>')
        self.info = {'version': '1.0.0+1', 'dependencies': ['flutter'], 'overrides': []}

    def tearDown(self):
        self.temp.cleanup()

    def put(self, path, text):
        dest = self.root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)
        return dest

    def test_standard_plan_and_custom_refusal(self):
        original = self.activity.read_text()
        plan, config = app.integration_plan(self.root, self.info, 'http://127.0.0.1:18091')
        self.assertEqual(self.activity.read_text(), original)
        self.assertIn('getDartEntrypointArgs', plan[self.activity])
        self.assertIn('apply(from', plan[self.gradle])
        self.assertEqual(config['appId'], 'com.example.demo')
        self.assertNotIn('release', config)  # pubspec remains the version authority.
        self.assertIn('includeSubdomains="false"', app.NETWORK)
        self.activity.write_text(original.replace('FlutterActivity()', 'FlutterActivity() { fun custom() {} }'))
        with self.assertRaises(ValueError):
            app.integration_plan(self.root, self.info, 'http://127.0.0.1:18091')
        self.assertFalse((self.root / '.hotfix').exists())

    def test_external_dart_source_is_used_for_app_override(self):
        source = self.root / 'explicit-sdk'
        plan, _ = app.integration_plan(self.root, self.info, 'https://patches.example.com', dart_source=source)
        self.assertIn('explicit-sdk/pkg/_fe_analyzer_shared', plan[self.root / 'pubspec.yaml'])

    def test_tool_paths_can_be_explicit_without_author_work_directory(self):
        args = argparse.Namespace(flutter_sdk='/tools/flutter', android_sdk='/tools/android',
                                  java_home='/tools/jdk', dart_sdk_source='/tools/dart', gen_snapshot='/tools/engine/generator')
        with patch.object(app, 'validate_tools'):
            env = app.tools_environment(args, {})
        self.assertEqual(env['DART_SDK_SOURCE'], '/tools/dart')
        self.assertEqual(env['GEN_SNAPSHOT'], '/tools/engine/generator')

    def test_groovy_https_and_conflicts(self):
        content = self.gradle.read_text().replace('applicationId =', 'applicationId')
        self.gradle.unlink()
        gradle = self.put('android/app/build.gradle', content)
        plan, config = app.integration_plan(self.root, self.info, 'https://patches.example.com')
        self.assertIn("apply from:", plan[gradle])
        self.assertFalse(config['allowDevelopmentHttp'])
        self.assertFalse(any('src/hotfix' in str(path) for path in plan))
        self.put('lib/main_hotfix.dart', '// user owned')
        with self.assertRaises(ValueError):
            app.integration_plan(self.root, self.info, 'https://patches.example.com')

    def test_dry_run_does_not_write_or_spawn(self):
        args = argparse.Namespace(origin='http://127.0.0.1:18091', keys=str(self.root / '.hotfix/keys'), dry_run=True)
        before = self.activity.read_text()
        with patch.object(app, 'tools_environment', return_value={}), patch.object(app, 'app_info', return_value=self.info), \
             patch.object(app, 'run', side_effect=AssertionError('spawned')):
            app.initialize(self.root, args)
        self.assertEqual(self.activity.read_text(), before)
        self.assertFalse((self.root / '.hotfix').exists())

    def test_origin_guards(self):
        for origin in ['http://remote.example', 'https://user:secret@example.com', 'https://example.com/api', 'https://example.com?q=x']:
            with self.assertRaises(ValueError):
                app.local_http(origin)

    def test_lan_requires_explicit_private_ipv4_and_exact_whitelist(self):
        origin = 'http://192.168.111.53:18091'
        with self.assertRaises(ValueError):
            app.local_http(origin)
        self.assertTrue(app.local_http(origin, True))
        for host in ['8.8.8.8', '169.254.1.1', '100.64.0.1', '0.0.0.0', 'localhost', 'example.com', '[::1]']:
            with self.assertRaises(ValueError):
                app.local_http('http://' + host + ':18091', True)
        for host in ['10.1.2.3', '172.16.1.2', '172.31.255.1']:
            self.assertTrue(app.local_http('http://' + host + ':18091', True))
        plan, config = app.integration_plan(self.root, self.info, origin, True)
        xml = plan[self.root / 'android/app/src/hotfix/res/xml/hotfix_network_security.xml']
        self.assertTrue(config['allowDevelopmentLan'])
        self.assertIn('>192.168.111.53<', xml)
        self.assertIn('includeSubdomains="false"', xml)
        self.assertIn('base-config cleartextTrafficPermitted="false"', xml)

    def test_lan_serve_binds_only_configured_interface(self):
        self.put('.hotfix/local.json', json.dumps({'schemaVersion': 1, 'ready': True,
                 'project': str(self.root), 'environment': {'HOTFIX_PUBLIC_KEY_FILE': '/test/public-key.txt'}}))
        self.put('hotfix.android.json', json.dumps({'updateOrigin': 'http://192.168.111.53:18095',
                 'allowDevelopmentLan': True, 'allowDevelopmentHttp': True}))
        with patch.object(app, 'invoke') as invoke:
            app.perform(self.root, 'serve')
        extra = invoke.call_args.kwargs['extra']
        self.assertEqual(extra['HOTFIX_BIND'], '192.168.111.53')
        self.assertEqual(extra['HOTFIX_PORT'], '18095')
        self.assertGreaterEqual(len(extra['HOTFIX_PUBLISH_TOKEN']), 24)

    def test_unignored_private_directory_refused_before_writes(self):
        self.put('.gitignore', '!/.hotfix/\n')
        args = argparse.Namespace(origin='http://127.0.0.1:18091', keys=str(self.root / '.hotfix/keys'), dry_run=False)
        before = self.activity.read_text()
        with patch.object(app, 'tools_environment', return_value={}), patch.object(app, 'app_info', return_value=self.info):
            with self.assertRaisesRegex(ValueError, '忽略'):
                app.initialize(self.root, args)
        self.assertEqual(self.activity.read_text(), before)
        self.assertFalse((self.root / '.hotfix').exists())

    def test_existing_config_is_not_overwritten(self):
        _, config = app.integration_plan(self.root, self.info, 'https://patches.example.com')
        self.put('hotfix.android.json', json.dumps(config))
        self.put('lib/main_hotfix.dart', '// custom integration')
        plan, _ = app.integration_plan(self.root, self.info, None)
        self.assertFalse(plan)
        with self.assertRaises(ValueError):
            app.integration_plan(self.root, self.info, 'https://another.example')

    def test_build_patch_publish_and_fail_closed(self):
        local = self.root / '.hotfix'
        app.save(local / 'local.json', {'schemaVersion': 1, 'ready': True, 'project': str(self.root), 'keys': 'test-keys', 'environment': {}})
        self.put('hotfix.android.json', json.dumps({'updateOrigin': 'https://patches.example.com', 'release': 'old'}))
        calls = []
        def backend(profile, action, *args, extra=None):
            calls.append(action)
            if action == 'release-android':
                config, output = Path(args[0]), Path(args[1])
                self.assertEqual(app.read(config)['release'], self.info['version'])
                app.save(output / 'android-release.json', {'schemaVersion': 1, 'appId': 'com.example.demo', 'release': '1.0.0+1', 'baselineId': 'a' * 64})
                app.save(output / 'baseline/project.json', {'project': str(self.root), 'updateOrigin': 'https://patches.example.com'})
                app.save(output / 'baseline/release/release.json', {'baselineId': 'a' * 64})
            elif action == 'patch-android':
                output = Path(args[2])
                app.save(output / 'manifest.json', {'manifest': {'baselineId': 'a' * 64, 'patchId': args[4]}})
                (output / 'patch.bytecode').write_bytes(b'compiled-test')
        with patch.object(app, 'validate_tools'), patch.object(app, 'head', return_value='b' * 40), \
             patch.object(app, 'app_info', return_value=self.info), patch.object(app, 'tool_stamp', return_value='stable'), \
             patch.object(app, 'invoke', side_effect=backend):
            app.perform(self.root, 'build')
            app.perform(self.root, 'patch')
            self.assertEqual(calls, ['release-android', 'patch-android'])
            with patch.dict(os.environ, {'HOTFIX_PUBLISH_TOKEN': 'test-only-' + 'x' * 32}):
                app.perform(self.root, 'publish', yes=True)
            self.assertEqual(calls[-1], 'publish')
            candidate = app.read(local / 'state.json')['patch']
            Path(candidate['path'], 'patch.bytecode').write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                app.perform(self.root, 'publish', yes=True)
            with patch.object(app, 'head', side_effect=ValueError('dirty')):
                with self.assertRaises(ValueError):
                    app.perform(self.root, 'patch')
            self.assertNotIn('patch', app.read(local / 'state.json'))
            with self.assertRaises(ValueError):
                app.perform(self.root, 'publish', yes=True)

    def test_changed_toolchain_blocks_patch(self):
        local = self.root / '.hotfix'
        app.save(local / 'local.json', {'schemaVersion': 1, 'ready': True, 'project': str(self.root), 'environment': {}})
        app.save(local / 'state.json', {'toolStamp': 'old'})
        with patch.object(app, 'validate_tools'), patch.object(app, 'head', return_value='b' * 40), \
             patch.object(app, 'app_info', return_value=self.info), patch.object(app, 'tool_stamp', return_value='new'), \
             patch.object(app, 'baseline_for', return_value=(local, {'release': '1.0.0+1'})), \
             patch.object(app, 'invoke', side_effect=AssertionError('compiler invoked')):
            with self.assertRaisesRegex(ValueError, '工具/运行时'):
                app.perform(self.root, 'patch')


if __name__ == '__main__':
    unittest.main()
