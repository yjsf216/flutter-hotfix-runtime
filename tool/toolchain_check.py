"""Read-only diagnostics and explicit SDK binding guards."""
import argparse
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import toolchain as tc


class ToolchainCheck(unittest.TestCase):
    def test_explicit_paths_win_without_returning_profile_secrets(self):
        args = argparse.Namespace(flutter_sdk='/new/flutter', dart_sdk_source='/new/dart',
                                  gen_snapshot='/new/engine/gen_snapshot', android_sdk='/new/android', java_home='/new/java')
        result = tc.discover(args, {'FLUTTER_SDK': '/old/flutter', 'SECRET_TOKEN': 'private'})
        self.assertEqual(result['DART_BIN'], '/new/flutter/bin/cache/dart-sdk/bin/dart')
        self.assertEqual(result['DART_SDK_SOURCE'], '/new/dart')
        self.assertNotIn('SECRET_TOKEN', result)

    def test_missing_environment_reports_all_failures_without_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(tc, 'ROOT', root), patch.object(tc, 'command', return_value=''):
                checks = tc.inspect({})
            failures = {item['name'] for item in checks if not item['ok']}
            self.assertTrue({'flutter-version', 'dart', 'jdk', 'android-platform', 'ddm-engine', 'dart-packages'} <= failures)
            self.assertEqual(list(root.iterdir()), [])

    def test_fixed_revision_and_ddm_flags_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            flutter, dart, build = root / 'flutter', root / 'dart', root / 'out'
            version = flutter / 'bin/internal/engine.version'
            version.parent.mkdir(parents=True)
            version.write_text('wrong')
            dart.mkdir()
            (dart / '.git').mkdir()
            build.mkdir()
            args = build / 'args.gn'
            args.write_text('target_os = "android"\ntarget_cpu = "arm64"\nflutter_runtime_mode = "release"\ndart_dynamic_modules = false\ndart_version = "' + tc.DART_REVISION + '"\n')
            env = {'FLUTTER_SDK': str(flutter), 'DART_SDK_SOURCE': str(dart),
                   'GEN_SNAPSHOT': str(build / 'artifacts_arm64/gen_snapshot_arm64')}
            with patch.object(tc, 'ROOT', root), patch.object(tc, 'command', return_value=tc.DART_REVISION):
                checks = {c['name']: c for c in tc.inspect(env)}
                self.assertFalse(checks['flutter-version']['ok'])
                self.assertFalse(checks['ddm-configuration']['ok'])
                self.assertTrue(checks['dart-revision']['ok'])
                version.write_text(tc.ENGINE_REVISION)
                args.write_text(args.read_text().replace('false', 'true'))
                checks = {c['name']: c for c in tc.inspect(env)}
                self.assertTrue(checks['flutter-version']['ok'])
                self.assertTrue(checks['ddm-configuration']['ok'])

    def test_binding_is_idempotent_and_refuses_replacement(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'prepared-dart'
            source.mkdir()
            with patch.object(tc, 'ROOT', root / 'runtime'):
                tc.bind_runtime_sdk({'DART_SDK_SOURCE': str(source)})
                tc.bind_runtime_sdk({'DART_SDK_SOURCE': str(source)})
                link = tc.ROOT / 'work/upstream/dart-sdk'
                self.assertEqual(link.resolve(), source.resolve())
                with self.assertRaises(ValueError):
                    tc.bind_runtime_sdk({'DART_SDK_SOURCE': str(root / 'other')})
                self.assertEqual(link.resolve(), source.resolve())


if __name__ == '__main__':
    unittest.main()
