"""Synthetic CLI responses only. Never calls cloud APIs or reads real credentials."""
from pathlib import Path
import tempfile
import unittest
from retire_aliyun import retire


class AdapterCheck(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for name in ['ossutil', 'aliyun', 'oss.conf']: (self.root / name).touch()
        self.env = {'HOTFIX_RETIRE_CONFIRM': 'true', 'HOTFIX_OSS_BUCKET': 'test-bucket',
                    'HOTFIX_OSS_PREFIX': 'hotfix-test', 'HOTFIX_CDN_BLOB_BASE': 'https://cdn.example.invalid/hotfix-test/v1/blobs/',
                    'HOTFIX_RETIRE_OSSUTIL': str(self.root/'ossutil'), 'HOTFIX_RETIRE_CDNCLI': str(self.root/'aliyun'),
                    'HOTFIX_OSS_CONFIG': str(self.root/'oss.conf'), 'HOTFIX_CDN_PROFILE': 'fixture',
                    'HOTFIX_RETIRE_STATE': str(self.root/'state')}
        self.calls = []; self.ready = False

    def execute(self, args):
        self.calls.append(args)
        if args[1] == 'rm':
            self.assertTrue(args[2].startswith('oss://test-bucket/hotfix-test/v1/blobs/'))
            self.assertNotIn('-r', args)
            return {}
        if args[2] == 'RefreshObjectCaches': return {'RefreshTaskId': '123'}
        return {'Tasks': {'CDNTask': [{'TaskId': '123', 'ObjectPath': args[args.index('--ObjectPath')+1],
                                      'Status': 'Complete' if self.ready else 'Refreshing'}]}}

    def test_default_off_and_invalid_paths_do_not_execute(self):
        with self.assertRaises(ValueError): retire({'schemaVersion': 1, 'hashes': ['a'*64]}, {}, self.execute)
        with self.assertRaises(ValueError): retire({'schemaVersion': 1, 'hashes': ['../all']}, self.env, self.execute)
        self.assertEqual(self.calls, [])

    def test_accepted_refresh_is_not_completion_and_retry_reuses_id(self):
        request = {'schemaVersion': 1, 'hashes': ['a'*64]}
        with self.assertRaisesRegex(ValueError, 'pending'): retire(request, self.env, self.execute)
        self.ready = True
        self.assertTrue(retire(request, self.env, self.execute)['cdnPurged'])
        self.assertEqual(sum(c[1]=='rm' for c in self.calls), 1)
        self.assertEqual(sum(c[1]=='cdn' and c[2]=='RefreshObjectCaches' for c in self.calls), 1)

    def test_large_batch_resumes_without_starvation(self):
        self.ready = True
        request = {'schemaVersion': 1, 'hashes': [f'{i:064x}' for i in range(6)]}
        with self.assertRaisesRegex(ValueError, 'pending'): retire(request, self.env, self.execute)
        self.assertEqual(len(retire(request, self.env, self.execute)['hashes']), 6)
        self.assertEqual(sum(c[1]=='rm' for c in self.calls), 6)


if __name__ == '__main__': unittest.main()
