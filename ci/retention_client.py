"""Optional Jenkins retention adapter. Never enables retention or publishes patches."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
from urllib.parse import urlsplit
from urllib.request import Request, build_opener
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool'))

from ci_baselines import Catalogue
from upload_patch import NoRedirect


class Client:
    def __init__(self, origin):
        uri = urlsplit(origin)
        if (uri.scheme != 'https' or not uri.hostname or uri.username or uri.password or uri.query or uri.fragment or
                not re.fullmatch(r'(?:/[A-Za-z0-9_-]+)*/?', uri.path)):
            raise ValueError('Fixed HTTPS management origin required')
        self.origin = origin.rstrip('/')
        self.token = os.environ.get('HOTFIX_UPLOAD_TOKEN', '')
        if len(self.token) < 24 or any(c in self.token for c in '\r\n'):
            raise ValueError('HOTFIX_UPLOAD_TOKEN required')

    def call(self, suffix='', body=None):
        request = Request(self.origin + '/v1/retention' + suffix,
                          data=None if body is None else json.dumps(body).encode(),
                          headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'},
                          method='GET' if body is None else 'POST')
        with build_opener(NoRedirect).open(request, timeout=30) as response:
            raw = response.read(4 * 1024 * 1024 + 1)
            if len(raw) > 4 * 1024 * 1024: raise ValueError('Oversized retention response')
            return json.loads(raw)

    @contextmanager
    def lease(self, identity, on_failure, heartbeat_interval=60):
        receipt = self.call('/lease', {'action': 'acquire', 'baselineId': identity})
        token = receipt['token']; stopped = threading.Event(); failed = threading.Event()
        def heartbeat():
            while not stopped.wait(heartbeat_interval):
                try: self.call('/lease', {'action': 'renew', 'baselineId': identity, 'token': token})
                except Exception:
                    failed.set(); on_failure(); return
        thread = threading.Thread(target=heartbeat, daemon=True); thread.start()
        try:
            yield
            if failed.is_set(): raise ValueError('Baseline lease lost; patch task aborted')
        finally:
            stopped.set(); thread.join(timeout=35)
            # A failed release leaves an expiring lease, not an unprotected build.
            try: self.call('/lease', {'action': 'release', 'baselineId': identity, 'token': token})
            except Exception: print('Lease release not confirmed; it will expire server-side', file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['status', 'register', 'patch'])
    parser.add_argument('--origin', required=True)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--channel')
    parser.add_argument('--baseline-id')
    parser.add_argument('--apply-local-retention', action='store_true')
    argv = sys.argv[1:]
    separator = argv.index('--') if '--' in argv else len(argv)
    args = parser.parse_args(argv[:separator])
    command = argv[separator + 1:]
    if command and args.action != 'patch': parser.error('command only supports patch')
    client = Client(args.origin)
    if args.action == 'status':
        print(json.dumps(client.call())); return
    if not args.root: parser.error('--root required')
    catalogue = Catalogue(args.root)
    if args.action == 'register':
        if not args.archive or not args.channel: parser.error('--archive and --channel required')
        receipt, _ = catalogue.completed(args.archive)
        identity = receipt['baselineId']
        remote = client.call('/register', {'baselineId': identity, 'channel': args.channel})
        catalogue.record(args.archive, remote)
        print(json.dumps({'baselineId': identity, 'retentionEnabled': remote['enabled'],
                          'cleanup': catalogue.prune(remote, args.apply_local_retention)}))
        return
    if not args.baseline_id or not re.fullmatch(r'[a-f0-9]{64}', args.baseline_id): parser.error('--baseline-id required')
    if not command: parser.error('patch requires -- command [arguments]')
    remote = client.call()
    if not any(r['baselineId'] == args.baseline_id for r in catalogue.available(remote)):
        raise ValueError('Baseline absent locally or retired; build a new base instead')
    process = None
    def cancel():
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            except ProcessLookupError: pass
    with catalogue.in_use(args.baseline_id) as archive:
        with client.lease(args.baseline_id, cancel):
            # The operator-supplied command must use the frozen archive, never
            # substitute a different baseline with the same version number.
            process = subprocess.Popen(command, start_new_session=True,
                                       env={**os.environ, 'HOTFIX_BASELINE_ARCHIVE': str(archive)})
            try: status = process.wait()
            finally: cancel()
            if status: raise ValueError('Patch command failed; no publication requested')
    remote = client.call()
    print(json.dumps({'cleanup': catalogue.prune(remote, args.apply_local_retention)}))


if __name__ == '__main__':
    try: main()
    except HTTPError as error: sys.exit('Retention API rejected request: HTTP ' + str(error.code))
    except (ValueError, OSError, KeyError) as error: sys.exit('ERROR: ' + str(error))
