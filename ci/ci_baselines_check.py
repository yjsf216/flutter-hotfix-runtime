"""Synthetic CI directories only; no Jenkins, credentials or device access."""
import json
from pathlib import Path
import tempfile
import unittest

from ci_baselines import Catalogue


class CatalogueCheck(unittest.TestCase):
    def test_completed_only_preview_and_locked_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            ordinary = root / 'ordinary-job'; ordinary.mkdir()
            (ordinary / 'keep').write_text('business')
            c = Catalogue(root / 'hotfix')
            directory = c.allocate(); archive = directory / 'archive'; archive.mkdir()
            identity = 'a' * 64
            row = {'baselineId': identity, 'appId': 'example.app', 'platform': 'android', 'release': '1.0.0+1', 'gitCommit': 'b' * 40}
            remote = {'enabled': False, 'records': [row]}
            with self.assertRaises(ValueError): c.record(archive, remote)
            (archive / 'android-release.json').write_text(json.dumps(row))
            (archive / 'baseline/release').mkdir(parents=True)
            (archive / 'baseline/project.json').write_text(json.dumps({'gitCommit': row['gitCommit']}))
            (archive / 'baseline/release/release.json').write_text(json.dumps({'baselineId': identity}))
            (archive / 'baseline/release/baseline.input.dill').write_bytes(b'frozen')
            (archive / 'baseline/release/baseline.aot.dill').write_bytes(b'frozen-aot')
            with self.assertRaises(ValueError): c.record(archive, {'records': []})
            c.record(archive, remote)
            self.assertEqual(len(c.available(remote)), 1)
            remote['records'][0]['retiredAt'] = '2026-01-01T00:00:00Z'
            self.assertEqual(c.available(remote), [])
            self.assertEqual(len(c.prune(remote)), 1)
            self.assertTrue(directory.exists())
            with self.assertRaises(ValueError): c.prune(remote, True)
            remote['enabled'] = True
            with c.in_use(identity): self.assertEqual(c.prune(remote, True), [])
            self.assertTrue(directory.exists())
            self.assertEqual(len(c.prune(remote, True)), 1)
            self.assertFalse(directory.exists())
            self.assertEqual((ordinary / 'keep').read_text(), 'business')

    def test_external_paths_and_symlinks_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); c = Catalogue(root / 'catalogue')
            with self.assertRaises(ValueError): c.owned(root / 'archive')
            directory = c.allocate()
            external = root / 'external'; external.mkdir()
            (directory / 'archive').symlink_to(external, target_is_directory=True)
            with self.assertRaises(ValueError): c.owned(directory / 'archive')
            with self.assertRaises(ValueError): Catalogue(Path.home())
            with self.assertRaises(ValueError): Catalogue('/')


if __name__ == '__main__': unittest.main()
