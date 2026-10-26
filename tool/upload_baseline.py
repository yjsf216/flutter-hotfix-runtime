"""Register a completed base archive and upload its package through the hosted API."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit
from urllib.request import Request, build_opener
from urllib.error import HTTPError, URLError

from android_release import digest, read, require
from upload_patch import NoRedirect


def upload(origin, archive, source_branch, source_commit):
    url = urlsplit(origin)
    require(url.scheme == 'https' and url.hostname and not url.username and not url.password
            and not url.query and not url.fragment
            and re.fullmatch(r'(?:/[A-Za-z0-9_-]+)*/?', url.path), 'HTTPS API base required')
    token = os.environ.get('HOTFIX_UPLOAD_TOKEN', '')
    require(len(token) >= 24 and not any(c in token for c in '\r\n'), 'Upload credential required')
    markers = [p for p in ('android', 'ios') if (archive / (p + '-release.json')).is_file()]
    require(len(markers) == 1, 'One completed release archive required')
    platform = markers[0]
    receipt = read(archive / (platform + '-release.json'))
    extension = 'apk' if platform == 'android' else 'ipa'
    package = archive / ('app.' + extension)
    require(package.is_file() and not package.is_symlink(), 'Regular installation package required')
    require(digest(package) == receipt[extension + 'Sha256'], 'Installation package changed')
    baseline = read(archive / 'baseline/project.json')
    require(baseline['gitCommit'] == receipt['gitCommit'], 'Archive Git identity mismatch')
    require(read(archive / 'baseline/release/release.json')['baselineId'] == receipt['baselineId'],
            'Archive baseline identity mismatch')
    require(re.fullmatch(r'[a-f0-9]{40}', source_commit), 'Full source commit required')
    subprocess.run(['git', 'merge-base', '--is-ancestor', source_commit, receipt['gitCommit']],
                   cwd=baseline['project'], check=True)
    metadata = {key: receipt[key] for key in ('baselineId', 'appId', 'release', 'gitCommit')}
    metadata.update(platform=platform, sourceBranch=source_branch, sourceCommit=source_commit,
                    packageSha256=receipt[extension + 'Sha256'], packageSize=package.stat().st_size)
    opener = build_opener(NoRedirect)

    def post(path, data, content_type='application/json'):
        request = Request(origin.rstrip('/') + '/v1/baselines' + path, data=data, method='POST',
                          headers={'Authorization': 'Bearer ' + token, 'Content-Type': content_type})
        with opener.open(request, timeout=240) as response:
            result = response.read(65537)
            require(len(result) <= 65536, 'Oversized receipt')
            return json.loads(result)

    result = post('', json.dumps(metadata).encode())
    require(result.get('baselineId') == metadata['baselineId'], 'Registration identity mismatch')
    if result.get('status') != 'registered':
        require(result.get('status') == 'staging' and result.get('chunkSize') == 4 * 1024 * 1024,
                'Unexpected upload protocol')
        with package.open('rb') as stream:
            index = 0
            while chunk := stream.read(result['chunkSize']):
                part = post('/' + metadata['baselineId'] + '/chunks/' + str(index), chunk,
                            'application/octet-stream')
                require(part.get('status') == 'staged' and part.get('index') == index, 'Chunk receipt mismatch')
                index += 1
                print(f'已上传 {min(index * result["chunkSize"], metadata["packageSize"])} / {metadata["packageSize"]} bytes', flush=True)
        result = post('/' + metadata['baselineId'] + '/finish', b'')
    require(result.get('status') == 'registered' and result.get('baselineId') == metadata['baselineId'],
            'Completed registration not confirmed')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('origin')
    parser.add_argument('archive', type=Path)
    parser.add_argument('--source-branch', required=True)
    parser.add_argument('--source-commit', required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(upload(args.origin, args.archive, args.source_branch, args.source_commit)))
    except HTTPError as error:
        sys.exit(f'Baseline upload rejected: HTTP {error.code}; retry the identical archive')
    except (URLError, OSError, ValueError, KeyError, subprocess.CalledProcessError):
        sys.exit('Baseline registration not confirmed; check archive/connectivity and retry')


if __name__ == '__main__':
    main()
