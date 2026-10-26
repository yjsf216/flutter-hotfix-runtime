"""Engine discovery/integrity checks without real SDKs or devices."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import engine_bundle as bundle


class EngineBundleCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.project = Path(self.tmp.name) / 'app'
        self.package = Path(self.tmp.name) / 'git cache/runtime'
        self.root = self.package / 'engine/test'
        self.root.mkdir(parents=True)
        (self.package / 'engine/current.json').write_text('{"manifest":"test/manifest.json"}')
        self.manifest = self.root / 'manifest.json'
        files = {}
        for name in ['android-arm64/artifacts_arm64/gen_snapshot_arm64',
                     'android-arm64/lib.stripped/libflutter.so', 'android-arm64/args.gn']:
            file = self.root / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b'fixture')
            file.chmod(0o755)
            files[name] = {'size': 7, 'sha256': hashlib.sha256(b'fixture').hexdigest(), 'executable': True}
        self.data = {'schemaVersion': 1, 'host': 'darwin-arm64',
                     'flutterRevision': bundle.FLUTTER, 'engineRevision': bundle.ENGINE, 'dartRevision': bundle.DART,
                     'targets': {'android': {'abi': 'arm64', 'mode': 'release', 'dynamicModules': True,
                         'generator': 'android-arm64/artifacts_arm64/gen_snapshot_arm64',
                         'engine': 'android-arm64/lib.stripped/libflutter.so', 'args': 'android-arm64/args.gn'}},
                     'files': files}
        self.write()
        config = self.project / '.dart_tool/package_config.json'
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({'packages': [{'name': 'patch_runtime', 'rootUri': self.package.as_uri()}]}))
        for name, value in [('system', 'Darwin'), ('machine', 'arm64')]:
            mock = patch.object(bundle.platform, name, return_value=value)
            mock.start()
            self.addCleanup(mock.stop)

    def write(self):
        self.manifest.write_text(json.dumps(self.data))

    def test_pub_cache_discovery_and_legacy_fallback(self):
        env = bundle.from_project(self.project, 'android')
        self.assertEqual(Path(env['GEN_SNAPSHOT']), (self.root / self.data['targets']['android']['generator']).resolve())
        self.assertEqual(Path(env['HOTFIX_ENGINE_MANIFEST']), self.manifest.resolve())
        (self.package / 'engine/current.json').unlink()
        self.assertIsNone(bundle.from_project(self.project, 'android'))

    def test_tampering_and_missing_resources_refused(self):
        name = self.data['targets']['android']['engine']
        (self.root / name).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            bundle.verify(self.manifest, 'android')
        (self.root / name).unlink()
        with self.assertRaises(ValueError):
            bundle.verify(self.manifest, 'android')

    def test_unlisted_file_refused(self):
        (self.root / 'extra.dylib').write_bytes(b'unlisted')
        with self.assertRaisesRegex(ValueError, 'unlisted'):
            bundle.verify(self.manifest, 'android')

    def test_host_platform_and_revision_refused(self):
        with patch.object(bundle.platform, 'machine', return_value='x86_64'):
            with self.assertRaises(ValueError): bundle.verify(self.manifest, 'android')
        with self.assertRaises(ValueError): bundle.verify(self.manifest, 'ohos')
        self.data['dartRevision'] = 'wrong'
        self.write()
        with self.assertRaises(ValueError): bundle.verify(self.manifest, 'android')

    def test_paths_symlinks_and_pairing_refused(self):
        with self.assertRaises(ValueError): bundle._inside(self.root, '../escape')
        with self.assertRaises(ValueError): bundle._inside(self.root, '/absolute')
        source = self.root / self.data['targets']['android']['engine']
        source.unlink()
        source.symlink_to(self.manifest)
        with self.assertRaises(ValueError): bundle.verify(self.manifest, 'android')


if __name__ == '__main__':
    unittest.main()
