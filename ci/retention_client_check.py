import contextlib
import io
import os
import time
import unittest
from unittest.mock import patch

import retention_client as client


class ClientCheck(unittest.TestCase):
    def test_https_and_credentials_guards(self):
        with patch.dict(os.environ, {'HOTFIX_UPLOAD_TOKEN': 'fixture-upload-token-1234567890'}):
            for origin in ['http://example.invalid', 'https://user:pass@example.invalid', 'https://example.invalid?q=1']:
                with self.assertRaises(ValueError): client.Client(origin)

    def test_lease_failure_calls_cancel_and_still_releases(self):
        actions = []; canceled = []
        def call(_, body):
            actions.append(body['action'])
            if body['action'] == 'renew': raise OSError('offline')
            return {'token': 'test-lease-token'}
        with patch.dict(os.environ, {'HOTFIX_UPLOAD_TOKEN': 'fixture-upload-token-1234567890'}):
            api = client.Client('https://example.invalid')
            with patch.object(api, 'call', side_effect=call):
                with self.assertRaisesRegex(ValueError, 'lease lost'):
                    with api.lease('a'*64, lambda: canceled.append(True), heartbeat_interval=0.001):
                        time.sleep(0.03)
        self.assertEqual(actions, ['acquire', 'renew', 'release'])
        self.assertEqual(canceled, [True])

    def test_cli_options_after_action_and_no_token_output(self):
        stream = io.StringIO()
        with patch.dict(os.environ, {'HOTFIX_UPLOAD_TOKEN': 'fixture-upload-token-1234567890'}), \
             patch.object(client.sys, 'argv', ['retention_client.py', 'status', '--origin', 'https://example.invalid']), \
             patch.object(client.Client, 'call', return_value={'enabled': False, 'records': []}), \
             contextlib.redirect_stdout(stream):
            client.main()
        self.assertIn('false', stream.getvalue())
        self.assertNotIn('token', stream.getvalue())


if __name__ == '__main__': unittest.main()
