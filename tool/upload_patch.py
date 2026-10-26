"""Upload a signed patch for later publication; storage credentials stay remote."""
import argparse
import base64
import json
import os
import re
from pathlib import Path
import sys
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from urllib.error import HTTPError, URLError


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def upload(origin, manifest, artifact, *, development=False):
    url = urlsplit(origin)
    local = development and url.scheme == 'http' and url.hostname == '127.0.0.1'
    if (not url.hostname or url.username or url.password or url.query or url.fragment
            or re.fullmatch(r'(?:/[A-Za-z0-9_-]+)*/?', url.path) is None
            or not (url.scheme == 'https' or local)):
        raise ValueError('Use an HTTPS service origin; development HTTP is loopback-only')
    token = os.environ.get('HOTFIX_UPLOAD_TOKEN', '')
    if len(token) < 24 or any(c in token for c in '\r\n'):
        raise ValueError('Set HOTFIX_UPLOAD_TOKEN to the server-issued upload credential')
    for file, limit in ((manifest, 16 * 1024), (artifact, 8 * 1024 * 1024)):
        if not file.is_file() or file.is_symlink() or file.stat().st_size > limit:
            raise ValueError('Missing, symlinked or oversized upload input')
    envelope = manifest.read_bytes()
    payload = artifact.read_bytes()
    expected = json.loads(envelope)['manifest']
    body = json.dumps({'envelope': base64.b64encode(envelope).decode(),
                       'artifact': base64.b64encode(payload).decode()}).encode()
    request = Request(origin.rstrip('/') + '/v1/uploads', data=body,
                      headers={'Authorization': 'Bearer ' + token,
                               'Content-Type': 'application/json'}, method='POST')
    with build_opener(NoRedirect).open(request, timeout=60) as response:
        if response.status != 201:
            raise ValueError('Unexpected upload response')
        data = response.read(65537)
        if len(data) > 65536:
            raise ValueError('Oversized upload response')
        result = json.loads(data)
    if (result.get('status') != 'uploaded' or any(result.get(field) != expected[field]
            for field in ('baselineId', 'patchId', 'artifactSha256'))):
        raise ValueError('Server receipt does not match the submitted patch')
    if expected.get('patchNumber') != result.get('patchNumber'):
        raise ValueError('Server receipt patch number mismatch')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('origin')
    parser.add_argument('patch', type=Path, help='Directory with manifest.json and patch.bytecode')
    parser.add_argument('--dev-loopback', action='store_true')
    args = parser.parse_args()
    try:
        result = upload(args.origin, args.patch / 'manifest.json', args.patch / 'patch.bytecode',
                        development=args.dev_loopback)
        print(json.dumps(result))
        print('上传已验证并暂存，尚未发布。')
    except HTTPError as error:
        sys.exit(f'Upload rejected: HTTP {error.code}; no publication requested')
    except (URLError, OSError, ValueError, KeyError):
        sys.exit('Upload not confirmed; check inputs/connectivity and retry the identical package')


if __name__ == '__main__':
    main()
