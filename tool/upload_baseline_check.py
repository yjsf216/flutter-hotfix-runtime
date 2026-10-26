import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from android_release import digest
import upload_baseline as uploader


class BaselineUploadCheck(unittest.TestCase):
    def test_verified_archive_chunk_protocol_and_corrupt_package_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'baseline/release').mkdir(parents=True)
            package = root / 'app.apk'
            package.write_bytes(b'package fixture')
            receipt = {'baselineId': 'a' * 64, 'appId': 'com.example.app',
                       'release': '1.2.3+4', 'gitCommit': 'b' * 40,
                       'apkSha256': digest(package)}
            (root / 'android-release.json').write_text(json.dumps(receipt))
            (root / 'baseline/project.json').write_text(json.dumps({'gitCommit': 'b' * 40, 'project': directory}))
            (root / 'baseline/release/release.json').write_text(json.dumps({'baselineId': 'a' * 64}))
            requests = []

            class Opener:
                def open(self, request, timeout):
                    requests.append(request)
                    if request.full_url.endswith('/chunks/0'):
                        response = {'status': 'staged', 'index': 0}
                    elif request.full_url.endswith('/finish'):
                        response = {'status': 'registered', 'baselineId': 'a' * 64}
                    else:
                        response = {'status': 'staging', 'baselineId': 'a' * 64, 'chunkSize': 4 * 1024 * 1024}
                    return io.BytesIO(json.dumps(response).encode())

            with patch.dict(os.environ, {'HOTFIX_UPLOAD_TOKEN': 'test-token-' + 'x' * 32}), \
                    patch.object(uploader, 'build_opener', return_value=Opener()), \
                    patch.object(uploader.subprocess, 'run') as git:
                result = uploader.upload('https://updates.example.com/hotfix', root, 'release/1.2.3', 'c' * 40)
                self.assertEqual(result['status'], 'registered')
                self.assertEqual(len(requests), 3)
                self.assertEqual(requests[1].data, package.read_bytes())
                self.assertTrue(all('/hotfix/v1/baselines' in r.full_url for r in requests))
                git.assert_called_once()
                package.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'changed'):
                    uploader.upload('https://updates.example.com/hotfix', root, 'release/1.2.3', 'c' * 40)
                self.assertEqual(len(requests), 3)


if __name__ == '__main__':
    unittest.main()
