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
