"""Read-only native discovery checks; mock build tools, never use signing accounts."""
import copy
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import project_config as cfg
import android_release
import ios_release


class ProjectConfigCheck(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'ios/Runner').mkdir(parents=True)
        (self.root / 'ios/Runner.xcodeproj').mkdir()
        (self.root / 'ios/Runner.xcodeproj/project.pbxproj').write_text('INFOPLIST_FILE = "$(HOTFIX_RUNNER_INFO_PLIST)";')

    def android(self, rows, config):
        with patch.object(cfg, '_run', return_value='noise\nPATCH_NATIVE_CONFIG=' + json.dumps(rows)) as run:
            result = cfg.resolve_config(config, self.root)
        return result, run.call_args.args[0]

    def ios(self, config, settings=None, schemes=None):
        settings = settings if settings is not None else {
            'WRAPPER_EXTENSION': 'app', 'DEVELOPMENT_TEAM': 'ABCDEFGHIJ',
            'IPHONEOS_DEPLOYMENT_TARGET': '13.0', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.example.app',
            'INFOPLIST_FILE': 'Runner/Info-Hotfix.plist',
        }
        with patch.object(cfg, '_run', side_effect=[
            json.dumps({'project': {'schemes': schemes or ['Runner']}}),
            json.dumps([{'buildSettings': settings}]),
        ]) as run:
            result = cfg.resolve_config(config, self.root)
        return result, run.call_args.args[0]

    def test_legacy_explicit_config_unchanged_without_tool_access(self):
        for value in [
            {'platform': 'android', 'androidFlavor': 'production', 'appId': 'com.example.app'},
            {'platform': 'ios', 'iosTeam': 'ABCDEFGHIJ', 'iosScheme': 'Runner',
             'iosMinimumVersion': '15.0', 'appId': 'com.example.app'},
        ]:
            before = copy.deepcopy(value)
            with patch.object(cfg, '_run', side_effect=AssertionError('tool invoked')):
                self.assertEqual(cfg.resolve_config(value, self.root), before)
            self.assertEqual(value, before)

    def test_exact_channel_and_evaluated_app_id(self):
        value = {'platform': 'android', 'dartDefines': {'APP_CHANNEL': 'test64'}, 'updateOrigin': 'https://updates.invalid'}
        before = copy.deepcopy(value)
        result, command = self.android([
            {'flavor': 'main64', 'appId': 'com.example.app'},
            {'flavor': 'test64', 'appId': 'com.example.app.test'},
        ], value)
        self.assertEqual(result['native'], {'flavor': 'test64'})
        self.assertEqual(result['appId'], 'com.example.app.test')
        self.assertEqual(result['updateOrigin'], value['updateOrigin'])
        self.assertTrue(any(str(a).startswith('-Pdart-defines=') for a in command))
        self.assertEqual(value, before)

    def test_ambiguous_or_invalid_channel_is_not_guessed(self):
        rows = [{'flavor': n, 'appId': 'com.example.' + n} for n in ['one', 'two']]
        for config in [{'platform': 'android'},
                       {'platform': 'android', 'dartDefines': {'APP_CHANNEL': 'unknown'}},
                       {'platform': 'android', 'native': {'flavor': 'unknown'}}]:
            with self.assertRaises(ValueError):
                self.android(rows, config)
        with self.assertRaisesRegex(ValueError, 'appId differs'):
            self.android(rows[:1], {'platform': 'android', 'appId': 'com.wrong'})

    def test_unflavored_project(self):
        result, _ = self.android([{'flavor': '', 'appId': 'com.example.app'}], {'platform': 'android'})
        self.assertEqual(cfg.native_options(result), {'flavor': ''})

    def test_android_selects_native_variant_by_abi(self):
        rows = [{'flavor': name, 'appId': 'com.example.app', 'abis': abis} for name, abis in
                [('mainch', ['armeabi-v7a']), ('main64', ['arm64-v8a']),
                 ('mainmerge', ['armeabi-v7a', 'arm64-v8a'])]]
        result, _ = self.android(rows, {'platform': 'android', 'abi': 'arm',
                                       'dartDefines': {'APP_CHANNEL': 'main64'}})
        self.assertEqual(result['native']['flavor'], 'mainch')
        with self.assertRaises(ValueError):
            self.android(rows, {'platform': 'android', 'abi': 'arm', 'native': {'flavor': 'main64'}})

    def test_conflicting_schema_and_unknown_options_rejected(self):
        for value in [{'platform': 'android', 'native': {}, 'androidFlavor': 'old'},
                      {'platform': 'android', 'native': {'team': 'ABCDEFGHIJ'}},
                      {'platform': 'ios', 'native': []},
                      {'platform': 'ios', 'native': {'team': ''}},
                      {'platform': 'android', 'iosTeam': 'ABCDEFGHIJ'}]:
            with self.assertRaises(ValueError):
                cfg.native_options(value)

    def test_ios_uses_effective_xcode_settings_and_dedicated_plist(self):
        plist = self.root / 'ios/Runner/Info-Hotfix.plist'
        plist.write_bytes(plistlib.dumps({'HotfixRuntimeEnabled': True}))
        result, command = self.ios({'platform': 'ios'})
        self.assertEqual(result['native'], {'team': 'ABCDEFGHIJ', 'scheme': 'Runner',
                         'minimumVersion': '13.0', 'infoPlist': 'Runner/Info-Hotfix.plist'})
        self.assertIn('HOTFIX_RUNNER_INFO_PLIST=Runner/Info-Hotfix.plist', command)
        self.assertNotIn('-allowProvisioningUpdates', command)

    def test_ios_requires_unique_scheme_and_signing_team(self):
        with self.assertRaisesRegex(ValueError, 'scheme'):
            self.ios({'platform': 'ios'}, schemes=['Runner', 'Other'])
        with self.assertRaisesRegex(ValueError, 'Team'):
            self.ios({'platform': 'ios'}, settings={'WRAPPER_EXTENSION': 'app', 'DEVELOPMENT_TEAM': ''})
        with self.assertRaisesRegex(ValueError, 'application target'):
            self.ios({'platform': 'ios'}, settings={'WRAPPER_EXTENSION': 'bundle'})

    def test_ios_partial_override_and_plist_guards(self):
        _, command = self.ios({'platform': 'ios', 'native': {'team': 'ABCDEFGHIJ'}})
        self.assertIn('DEVELOPMENT_TEAM=ABCDEFGHIJ', command)
        with self.assertRaisesRegex(ValueError, 'inside ios'):
            self.ios({'platform': 'ios', 'native': {'infoPlist': '../outside.plist'}})
        (self.root / 'ios/Runner/Info-Hotfix.plist').write_bytes(plistlib.dumps({'HotfixRuntimeEnabled': False}))
        with self.assertRaisesRegex(ValueError, 'does not enable'):
            self.ios({'platform': 'ios'})

    def test_both_packagers_freeze_resolved_config_before_native_build(self):
        (self.root / '.git').mkdir()
        (self.root / 'pubspec.yaml').write_text('version: 1.0.0+1\n')
        generator = self.root / 'engine/artifacts_arm64/gen_snapshot'
        generator.parent.mkdir(parents=True)
        generator.touch()
        for relative in ['lib.stripped/libflutter.so', 'Flutter.framework/Flutter']:
            file = self.root / 'engine' / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.touch()
        (self.root / 'engine/lib.stripped/libflutter.so').write_bytes(
            b'\x7fELF\x02\x01' + bytes(12) + (183).to_bytes(2, 'little'))
        environment = {'FLUTTER_SDK': str(self.root), 'GEN_SNAPSHOT': str(generator),
                       'ANDROID_BUILD_TOOLS': str(self.root)}
        for platform, build, native in [
            ('android', android_release, {'flavor': 'main'}),
            ('ios', ios_release, {'team': 'ABCDEFGHIJ', 'scheme': 'Runner', 'minimumVersion': '13.0'}),
        ]:
            config = {'project': '.', 'platform': platform, 'entry': 'lib/main_hotfix.dart', 'release': '1.0.0+1'}
            source = self.root / (platform + '.json')
            source.write_text(json.dumps(config))
            resolved = {**config, 'appId': 'com.example.app', 'native': native}
            output = self.root / (platform + '-archive')
            with patch.dict(os.environ, environment), patch.object(build, 'head', return_value='commit'), \
                 patch.object(build, 'resolve_config', return_value=resolved), \
                 patch.object(build, 'run', side_effect=RuntimeError('stop before actual build')):
                with self.assertRaisesRegex(RuntimeError, 'stop before'):
                    build.release(source, output)
            frozen = json.loads((output / 'resolved-config.json').read_text())
            self.assertEqual(frozen['native'], native)
            self.assertEqual(frozen['appId'], 'com.example.app')
            self.assertEqual(frozen['project'], str(self.root.resolve()))
            self.assertEqual(json.loads(source.read_text()), config)


if __name__ == '__main__':
    unittest.main()
