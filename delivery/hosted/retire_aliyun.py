#!/usr/bin/env python3
"""Opt-in exact-object OSS deletion and CDN purge; never accepts bucket-wide paths."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit


def run(args):
    # CLI credentials are provided by their private config/profile, not argv.
    result = subprocess.run(args, capture_output=True, text=True, timeout=20)
    if result.returncode: raise ValueError('Cloud operation not confirmed')
    return json.loads(result.stdout) if result.stdout.strip().startswith('{') else {}


def save(path, value):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as stream:
        json.dump(value, stream); stream.flush(); os.fsync(stream.fileno())
    temporary.replace(path)


def retire(request, env, execute=run):
    if env.get('HOTFIX_RETIRE_CONFIRM') != 'true': raise ValueError('Artifact retirement disabled')
    hashes = request.get('hashes')
    if (request.get('schemaVersion') != 1 or set(request) != {'schemaVersion', 'hashes'} or
            not isinstance(hashes, list) or not 1 <= len(hashes) <= 1000 or len(set(hashes)) != len(hashes) or
            any(not isinstance(h, str) or not re.fullmatch(r'[a-f0-9]{64}', h) for h in hashes)):
        raise ValueError('Invalid exact digest list')
    bucket, prefix, base = (env[k] for k in ['HOTFIX_OSS_BUCKET', 'HOTFIX_OSS_PREFIX', 'HOTFIX_CDN_BLOB_BASE'])
    url = urlsplit(base)
    if (not re.fullmatch(r'[a-z0-9][a-z0-9-]{1,61}[a-z0-9]', bucket) or
            not re.fullmatch(r'[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*', prefix) or
            url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment or
            not url.path.endswith('/v1/blobs/')):
        raise ValueError('Invalid dedicated storage namespace')
    oss, cdn, config = (env[k] for k in ['HOTFIX_RETIRE_OSSUTIL', 'HOTFIX_RETIRE_CDNCLI', 'HOTFIX_OSS_CONFIG'])
    if any(not Path(p).is_absolute() or not Path(p).is_file() for p in [oss, cdn, config]):
        raise ValueError('Explicit installed cloud CLI/config paths required')
    profile = env['HOTFIX_CDN_PROFILE']
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,100}', profile): raise ValueError('Invalid CDN CLI profile')
    state = Path(env['HOTFIX_RETIRE_STATE'])
    if not state.is_absolute() or state.is_symlink(): raise ValueError('Private absolute retirement state directory required')
    namespace = hashlib.sha256(json.dumps([bucket, prefix, base]).encode()).hexdigest()
    state = state / namespace; state.mkdir(parents=True, exist_ok=True, mode=0o700)
    complete = True
    # Bound each service invocation. Persist progress so retries don't re-submit
    # accepted CDN tasks; the periodic worker resumes remaining digests later.
    processed = 0
    for digest in hashes:
        path = state / (digest + '.json')
        if path.is_symlink(): raise ValueError('Retirement receipt cannot be a symlink')
        receipt = json.loads(path.read_text()) if path.exists() else {}
        if receipt.get('complete') is True: continue
        if processed >= 5:
            complete = False; continue
        processed += 1
        target = base + digest
        if not receipt.get('originDeleted'):
            execute([oss, 'rm', f'oss://{bucket}/{prefix}/v1/blobs/{digest}', '-f', '-c', config])
            receipt['originDeleted'] = True; save(path, receipt)
        if not receipt.get('taskIds'):
            result = execute([cdn, 'cdn', 'RefreshObjectCaches', '--ObjectPath', target,
                              '--ObjectType', 'File', '--profile', profile])
            tasks = str(result.get('RefreshTaskId', '')).split(',')
            if not tasks or any(not re.fullmatch(r'[0-9]+', t) for t in tasks):
                raise ValueError('CDN did not return valid refresh task IDs')
            receipt['taskIds'] = tasks; save(path, receipt)
        statuses = []
        if not isinstance(receipt['taskIds'], list) or not receipt['taskIds'] or any(
                not isinstance(task, str) or not re.fullmatch(r'[0-9]+', task) for task in receipt['taskIds']):
            raise ValueError('Invalid persisted refresh task')
        for task in receipt['taskIds']:
            result = execute([cdn, 'cdn', 'DescribeRefreshTasks', '--TaskId', task,
                              '--ObjectPath', target, '--profile', profile])
            rows = result.get('Tasks', {}).get('CDNTask', [])
            matches = [r for r in rows if str(r.get('TaskId')) == task and r.get('ObjectPath') == target]
            statuses.append(bool(matches) and all(r.get('Status') == 'Complete' for r in matches))
        receipt['complete'] = all(statuses); save(path, receipt)
        complete = complete and receipt['complete']
    if not complete: raise ValueError('CDN refresh pending; retry later using saved task IDs')
    return {'originDeleted': True, 'cdnPurged': True, 'hashes': hashes}


if __name__ == '__main__':
    try:
        raw = sys.stdin.buffer.read(128 * 1024 + 1)
        if len(raw) > 128 * 1024: raise ValueError('Oversized request')
        print(json.dumps(retire(json.loads(raw), os.environ)))
    except Exception:
        sys.stderr.write('Artifact retirement incomplete; details withheld to protect credentials\n')
        sys.exit(1)
