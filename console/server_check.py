"""Console contracts: real HTTP/Git; mocked compiler, no devices or publications."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import server


class ConsoleCheck(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.project = Path(self.temp.name).resolve() / 'app'
        self.project.mkdir()
        subprocess.run(['git', 'init', '-q', self.project], check=True)
        subprocess.run(['git', '-C', self.project, 'config', 'user.name', 'Test'], check=True)
        subprocess.run(['git', '-C', self.project, 'config', 'user.email', 'test@example.invalid'], check=True)
        (self.project / '.gitignore').write_text('.hotfix/\nandroid/local.properties\nandroid/key.properties\n')
        (self.project / 'pubspec.yaml').write_text('name: demo\nversion: 1.0.0+1\n')
        subprocess.run(['git', '-C', self.project, 'add', '.'], check=True)
        subprocess.run(['git', '-C', self.project, 'commit', '-qm', 'base'], check=True)
        self.commit = server.app.run(['git', '-C', self.project, 'rev-parse', 'HEAD'], capture=True).strip()
        server.app.save(self.project / '.hotfix/local.json', {'ready': True, 'project': str(self.project),
                        'keys': str(self.project / '.hotfix/keys'), 'environment': {'FLUTTER_SDK': '/missing'}})
        self.console = server.Console(self.project)

    def tearDown(self):
        self.console.close()
        self.temp.cleanup()

    def wait(self):
        limit = time.monotonic() + 5
        while self.console.active and time.monotonic() < limit:
            time.sleep(.01)
        self.assertIsNone(self.console.active)
        return self.console.state['tasks'][-1]

    def test_clone_never_changes_original_and_persists(self):
        task = self.console.submit({'action': 'refresh'})
        self.assertEqual(self.wait()['status'], 'succeeded')
        self.assertEqual(server.app.run(['git', '-C', self.project, 'rev-parse', 'HEAD'], capture=True).strip(), self.commit)
        self.assertEqual(self.console.git('rev-parse', 'HEAD'), self.commit)
        self.assertEqual(server.app.read(self.console.workspace / '.hotfix/local.json')['project'], str(self.console.workspace))
        self.assertEqual(server.app.read(self.console.file)['tasks'][-1]['id'], task['id'])
        self.assertEqual(os.stat(self.console.token_file).st_mode & 0o777, 0o600)

    def test_input_lock_stamp_and_confirmation_guards(self):
        for body in ({'action': 'invalid'}, {'action': 'build', 'commit': '--upload-pack=evil'},
                     {'action': 'build', 'commit': 'f' * 40}, {'action': 'publish', 'patch': 'none'}):
            with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                self.console.submit(body)
        self.console.state['baselines'].append({'id': 'base', 'toolStamp': 'wrong'})
        with self.assertRaisesRegex(ValueError, '工具源码'):
            self.console.submit({'action': 'patch', 'commit': self.commit, 'baseline': 'base'})
        self.console.active = 'busy'
        with self.assertRaisesRegex(ValueError, '已有任务'):
            self.console.submit({'action': 'refresh'})
        self.console.active = None
        self.console.state['patches'].append({'id': 'patch', 'status': 'ready'})
        with self.assertRaisesRegex(ValueError, '确认'):
            self.console.submit({'action': 'publish', 'patch': 'patch'})
        self.console.state['patches'][-1]['status'] = 'withdrawn'
        with self.assertRaisesRegex(ValueError, '已撤回'):
            self.console.submit({'action': 'publish', 'patch': 'patch', 'confirmed': True})

    def test_unignored_console_refused_before_writes(self):
        self.console.close()
        previous = self.console.file.stat().st_mtime_ns
        (self.project / '.gitignore').write_text('')
        with self.assertRaisesRegex(ValueError, '完全忽略'):
            server.Console(self.project)
        self.assertEqual(self.console.file.stat().st_mtime_ns, previous)

    def test_failure_cannot_create_success_or_artifact(self):
        with patch.object(self.console, 'prepare', side_effect=ValueError('toolchain absent')):
            self.console.submit({'action': 'build', 'commit': self.commit})
            task = self.wait()
        self.assertEqual(task['status'], 'failed')
        self.assertEqual(task['error'], 'toolchain absent')
        self.assertEqual(self.console.state['baselines'], [])

    def test_owned_workspace_refuses_foreign_directory(self):
        self.console.workspace.mkdir()
        with self.assertRaises((ValueError, OSError)):
            self.console.prepare({'id': 'a' * 24})
        self.assertEqual(list(self.console.workspace.iterdir()), [])

    def test_failed_ios_build_keeps_generated_evidence_and_restores_owned_inputs(self):
        originals = {'ios/Runner.xcodeproj/project.pbxproj': b'project input',
                     'ios/Runner/Info.plist': b'plist input'}
        for relative, content in originals.items():
            file = self.project / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(content)
        subprocess.run(['git', '-C', self.project, 'add', 'ios'], check=True)
        subprocess.run(['git', '-C', self.project, 'commit', '-qm', 'ios inputs'], check=True)
        commit = server.app.run(['git', '-C', self.project, 'rev-parse', 'HEAD'], capture=True).strip()
        self.console.profile['platform'] = 'ios'
        original_execute = self.console.execute

        def execute(task, command, *args, **kwargs):
            if any(str(part).endswith('/tool/app_cli.py') for part in command):
                for relative in originals:
                    (self.console.workspace / relative).write_bytes(b'generated on failure')
                raise ValueError('native build failed')
            return original_execute(task, command, *args, **kwargs)

        with patch.object(self.console, 'prepare_dependencies'), patch.object(self.console, 'execute', side_effect=execute):
            task = self.console.submit({'action': 'build', 'commit': commit})
            self.assertEqual(self.wait()['status'], 'failed')
        for relative, content in originals.items():
            self.assertEqual((self.console.workspace / relative).read_bytes(), content)
            evidence = self.console.root / (task['id'] + '.generated') / relative
            self.assertEqual(evidence.read_bytes(), b'generated on failure')
        self.assertEqual(self.console.git('status', '--porcelain'), '')
        self.assertEqual(self.console.state['baselines'], [])

    def test_platforms_use_separate_profiles_workspaces_and_process_environment(self):
        server.app.save(self.project / '.hotfix/ios/local.json', {'ready': True, 'platform': 'ios',
            'project': str(self.project), 'keys': '/private/test-keys', 'environment': {'FLUTTER_SDK': '/missing'}})
        ios = server.Console(self.project, 'ios')
        try:
            self.assertNotEqual(ios.workspace, self.console.workspace)
            self.assertEqual(ios.local, self.project / '.hotfix/ios')
            self.assertNotEqual(ios.token_file, self.console.token_file)
            task = {'id': '9' * 24}
            ios.prepare(task)
            self.assertTrue((ios.workspace / '.hotfix/ios/local.json').exists())
            import sys
            ios.execute(task, [sys.executable, '-c', 'import os; print(os.environ.get("HOTFIX_ACTIVE_PLATFORM"))'])
            self.assertTrue((ios.root / (task['id'] + '.log')).read_text().rstrip().endswith('ios'))
        finally:
            ios.close()

    def test_local_dependency_lock_copied_but_tracked_lock_preserved(self):
        self.console.prepare({'id': 'c' * 24})
        source = self.project / 'pubspec.lock'
        target = self.console.workspace / 'pubspec.lock'
        source.write_text('operator resolved dependencies')
        with patch.object(self.console, 'execute'):
            self.console.prepare_dependencies({'id': 'd' * 24})
        self.assertEqual(target.read_bytes(), source.read_bytes())
        target.write_text('commit owned dependencies')
        self.console.git('add', 'pubspec.lock')
        with patch.object(self.console, 'execute'):
            self.console.prepare_dependencies({'id': 'd' * 24})
        self.assertEqual(target.read_text(), 'commit owned dependencies')

    def test_patch_restores_selected_baseline_properties_and_rejects_tampering(self):
        self.console.prepare({'id': 'a' * 24})
        props = self.console.workspace / 'android/local.properties'
        props.parent.mkdir(parents=True)
        records = []
        for number in (1, 2):
            props.write_text(f'flutter.buildMode=release\nflutter.versionCode={number}\n')
            archive = self.console.root / ('base-' + str(number))
            server.app.save(archive / 'baseline/project.json', {'sources': {'android/local.properties': server.app.digest(props)}})
            frozen = self.console.freeze_local_properties(archive, {'id': str(number) * 24})
            records.append({'path': str(archive), 'localProperties': frozen})
        self.console.restore_local_properties(records[0])
        self.assertIn('flutter.versionCode=1', props.read_text())
        original = self.project / 'android/local.properties'
        original.parent.mkdir(parents=True)
        original.write_text('flutter.buildMode=debug\n')
        self.console.prepare({'id': 'b' * 24, 'action': 'patch'})
        self.assertIn('flutter.buildMode=release', props.read_text())
        self.console.restore_local_properties(records[1])
        self.assertIn('flutter.versionCode=2', props.read_text())
        Path(records[0]['localProperties']['path']).write_text('tampered')
        with self.assertRaisesRegex(ValueError, '已被修改'):
            self.console.restore_local_properties(records[0])

    def test_android_dependency_resolution_preserves_only_desktop_registrants(self):
        self.console.prepare({'id': 'e' * 24})
        desktop = self.console.workspace / 'macos/Flutter/GeneratedPluginRegistrant.swift'
        desktop.parent.mkdir(parents=True)
        desktop.write_text('selected commit desktop registration')
        dart = self.console.workspace / 'lib/main.dart'
        dart.parent.mkdir()
        dart.write_text('original Dart source')
        self.console.git('add', 'macos/Flutter/GeneratedPluginRegistrant.swift', 'lib/main.dart')
        def generate(*args):
            desktop.write_text('pub generated desktop registration')
            dart.write_text('unexpected Dart change')
        with patch.object(self.console, 'execute', side_effect=generate):
            self.console.prepare_dependencies({'id': 'f' * 24})
        self.assertEqual(desktop.read_text(), 'selected commit desktop registration')
        self.assertEqual(dart.read_text(), 'unexpected Dart change')
        self.assertEqual((self.console.root / (('f' * 24) + '.generated') / 'macos/Flutter/GeneratedPluginRegistrant.swift').read_text(),
                         'pub generated desktop registration')

    def test_ios_generated_inputs_are_frozen_per_baseline_and_private(self):
        self.console.prepare({'id': '1' * 24})
        generated = self.console.workspace / 'ios/Flutter/Generated.xcconfig'
        generated.parent.mkdir(parents=True)
        generated.write_text('FLUTTER_BUILD_MODE=release\n')
        archive = self.console.root / 'ios-base'
        server.app.save(archive / 'baseline/project.json', {'platform': 'ios', 'sources': {
            'ios/Flutter/Generated.xcconfig': server.app.digest(generated)}})
        saved = self.console.freeze_ios_inputs(archive, {'id': '2' * 24})
        base = {'id': 'base', 'path': str(archive), 'iosInputs': saved}
        generated.write_text('FLUTTER_BUILD_MODE=debug\n')
        self.console.restore_ios_inputs(base)
        self.assertEqual(generated.read_text(), 'FLUTTER_BUILD_MODE=release\n')
        self.console.state['baselines'].append(base)
        self.assertNotIn('iosInputs', self.console.snapshot()['baselines'][0])
        Path(saved['ios/Flutter/Generated.xcconfig']['path']).write_text('tampered')
        with self.assertRaisesRegex(ValueError, '冻结输入'):
            self.console.restore_ios_inputs(base)

    def test_restart_marks_running_interrupted_and_excludes_secrets(self):
        self.console.state['tasks'].append({'id': 'a' * 24, 'status': 'running'})
        self.console.persist()
        self.console.close()
        self.console = server.Console(self.project)
        self.assertEqual(self.console.state['tasks'][0]['status'], 'interrupted')
        snapshot = self.console.snapshot()
        self.assertNotIn(self.console.token, json.dumps(snapshot))
        self.assertNotIn('keys', snapshot)

    def test_http_auth_origin_paths_and_request_limits(self):
        http = server.ThreadingHTTPServer(('127.0.0.1', 0), server.handler(self.console))
        thread = threading.Thread(target=http.serve_forever, daemon=True)
        thread.start()
        def request(method, path, body=None, extra=None):
            conn = http_module.HTTPConnection('127.0.0.1', http.server_port, timeout=3)
            headers = {'Authorization': 'Bearer ' + self.console.token, **(extra or {})}
            conn.request(method, path, body=body, headers=headers)
            result = conn.getresponse()
            status, content = result.status, result.read()
            conn.close()
            return status, content
        # Local variable named http intentionally refers to the server.
        import http.client as http_module
        try:
            self.assertEqual(request('GET', '/api/state', extra={'Authorization': 'wrong'})[0], 401)
            self.assertEqual(request('GET', '/api/state', extra={'Host': 'attacker.invalid'})[0], 400)
            self.assertEqual(request('GET', '/api/state', extra={'Origin': 'https://evil.invalid'})[0], 400)
            self.assertEqual(request('GET', '/api/state')[0], 200)
            archive = self.console.root / 'ios-archive'
            archive.mkdir()
            (archive / 'app.ipa').write_bytes(b'signed-ipa-test')
            self.console.state['baselines'].append({'id': 'ios-base', 'platform': 'ios', 'path': str(archive),
                'ipaSha256': server.app.digest(archive / 'app.ipa')})
            self.assertEqual(request('GET', '/api/package/ios-base'), (200, b'signed-ipa-test'))
            (archive / 'app.ipa').write_bytes(b'tampered')
            self.assertEqual(request('GET', '/api/package/ios-base')[0], 400)
            self.assertEqual(request('GET', '/api/log/../../access-token')[0], 400)
            self.assertEqual(request('GET', '/../server.py')[0], 400)
            self.assertEqual(request('POST', '/api/tasks', '[]', {'Content-Type': 'application/json'})[0], 400)
            self.assertEqual(request('POST', '/api/tasks', 'x' * 4097, {'Content-Type': 'application/json'})[0], 400)
        finally:
            http.shutdown()
            http.server_close()

    def test_tampered_patch_rejected_before_network(self):
        directory = self.project / '.hotfix/patch'
        directory.mkdir()
        (directory / 'manifest.json').write_text('{}')
        (directory / 'patch.bytecode').write_text('altered')
        self.console.state['patches'].append({'id': 'p', 'path': str(directory), 'manifestSha256': 'wrong', 'artifactSha256': 'wrong'})
        with patch.object(self.console, 'execute', side_effect=AssertionError('network')):
            with self.assertRaisesRegex(ValueError, '产物已被修改'):
                self.console.publication({'action': 'publish', 'patch': 'p'})

    def test_publication_failure_is_unknown_and_retry_reuses_same_artifact(self):
        directory = self.project / '.hotfix/patch'
        directory.mkdir()
        (directory / 'manifest.json').write_text('{}')
        (directory / 'patch.bytecode').write_text('bytecode')
        base = self.project / '.hotfix/base'
        server.app.save(base / 'baseline/project.json', {'updateOrigin': 'https://frozen.example.invalid'})
        candidate = {'id': 'p', 'path': str(directory), 'baseline': str(base), 'status': 'ready',
                     'manifestSha256': server.app.digest(directory / 'manifest.json'),
                     'artifactSha256': server.app.digest(directory / 'patch.bytecode')}
        self.console.state['patches'].append(candidate)
        calls = []
        def upload(task, args, **kwargs):
            self.assertEqual(candidate['status'], 'publication-unknown')
            calls.append([str(a) for a in args])
            if len(calls) == 1:
                raise ValueError('connection lost after upload')
        with patch.dict(os.environ, {'HOTFIX_PUBLISH_TOKEN': 't' * 32}), patch.object(self.console, 'execute', side_effect=upload):
            with self.assertRaises(ValueError):
                self.console.publication({'action': 'publish', 'patch': 'p'})
            self.assertEqual(candidate['status'], 'publication-unknown')
            self.console.publication({'action': 'publish', 'patch': 'p'})
        self.assertEqual(candidate['status'], 'published')
        self.assertEqual(calls[0], calls[1])
        self.assertIn('https://frozen.example.invalid', calls[0])

    def test_large_build_log_keeps_final_error_and_redacts_tail(self):
        import sys
        task = {'id': '8' * 24}
        script = 'import sys; print("BUILD START"); sys.stdout.write("x" * (9 * 1024 * 1024)); print(); print(sys.argv[1]); print("FINAL FAILURE")'
        self.console.execute(task, [sys.executable, '-c', script, self.console.token])
        content = (self.console.root / (task['id'] + '.log')).read_bytes()
        self.assertTrue(content.startswith(b'BUILD START'))
        self.assertTrue(content.endswith(b'FINAL FAILURE\n'))
        self.assertIn(b'output omitted', content)
        self.assertIn(b'[REDACTED]', content)
        self.assertNotIn(self.console.token.encode(), content)
        self.assertLess(len(content), 8 * 1024 * 1024 + 100)

    def test_build_environment_does_not_inherit_publish_token_and_logs_redact(self):
        task = {'id': 'b' * 24}
        import sys
        with patch.dict(os.environ, {'HOTFIX_PUBLISH_TOKEN': 'secret-test-token-' * 2}):
            self.console.execute(task, [sys.executable, '-c',
                'import os; print("present" if "HOTFIX_PUBLISH_TOKEN" in os.environ else "absent")'])
            self.assertEqual((self.console.root / (task['id'] + '.log')).read_text().strip(), 'absent')
            self.console.execute(task, [sys.executable, '-c', 'import os; print(os.environ["HOTFIX_PUBLISH_TOKEN"])'],
                                 extra={'HOTFIX_PUBLISH_TOKEN': os.environ['HOTFIX_PUBLISH_TOKEN']})
        self.assertIn('[REDACTED]', (self.console.root / (task['id'] + '.log')).read_text())


if __name__ == '__main__':
    unittest.main()
