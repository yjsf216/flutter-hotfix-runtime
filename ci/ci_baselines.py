"""Isolated CI baseline catalogue; preview by default, never clean ordinary workspaces."""
import argparse
from contextlib import contextmanager
import fcntl
import json
from pathlib import Path
import re
import secrets
import shutil
import sys


def read(path):
    return json.loads(Path(path).read_text())


def save(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


class Catalogue:
    def __init__(self, root):
        requested = Path(root).absolute()
        if requested.is_symlink() or requested.resolve() in (Path('/'), Path.home().resolve()):
            raise ValueError('Dedicated CI catalogue directory required')
        self.root = requested.resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.index = self.root / 'index.json'
        self.builds = self.root / 'builds'
        if self.index.is_symlink() or self.builds.is_symlink() or (self.root / '.lock').is_symlink():
            raise ValueError('Catalogue paths cannot be symlinks')
        self.builds.mkdir(exist_ok=True)

    @contextmanager
    def locked(self):
        with (self.root / '.lock').open('a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            yield

    def rows(self):
        return read(self.index) if self.index.exists() else {}

    def allocate(self):
        with self.locked():
            identity = secrets.token_hex(16)
            directory = self.builds / identity
            directory.mkdir(mode=0o700)
            save(directory / '.ci-owned.json', {'schemaVersion': 1, 'buildId': identity})
            return directory

    def owned(self, archive, allow_missing=False):
        archive = Path(archive).absolute()
        directory = archive.parent
        if (self.root.is_symlink() or self.builds.is_symlink() or
                archive.name != 'archive' or directory.parent != self.builds or
                not re.fullmatch(r'[a-f0-9]{32}', directory.name) or
                directory.is_symlink() or archive.is_symlink() or
                (directory / '.ci-owned.json').is_symlink() or (directory / '.busy').is_symlink()):
            raise ValueError('Not an owned CI build directory')
        if allow_missing and not directory.exists(): return directory
        if read(directory / '.ci-owned.json') != {'schemaVersion': 1, 'buildId': directory.name}:
            raise ValueError('CI ownership marker mismatch')
        # Owned directories may contain cloned dependency links; never traverse
        # them during deletion. The root and marker themselves must be regular.
        return directory

    def record(self, archive, remote):
        with self.locked():
            archive = Path(archive).absolute()
            self.owned(archive)
            receipt, platform = self.completed(archive)
            identity = receipt['baselineId']
            if not re.fullmatch(r'[a-f0-9]{64}', identity): raise ValueError('Invalid baseline ID')
            accepted = [r for r in remote['records'] if r['baselineId'] == identity and not r.get('retiredAt')]
            if len(accepted) != 1 or any(accepted[0][k] != value for k, value in
                    [('appId', receipt['appId']), ('platform', platform), ('release', receipt['release'])]):
                raise ValueError('Server has not confirmed this completed baseline')
            if accepted[0].get('abi', 'arm64') != receipt.get('abi', 'arm64'):
                raise ValueError('Server ABI differs from completed baseline')
            rows = self.rows()
            if identity in rows and rows[identity]['archive'] != str(archive):
                raise ValueError('Baseline location is immutable')
            rows[identity] = {**accepted[0], 'archive': str(archive)}
            save(self.index, rows)
            return identity

    def completed(self, archive):
        archive = Path(archive).absolute(); self.owned(archive)
        receipts = [p for p in (archive / 'android-release.json', archive / 'ios-release.json') if p.is_file() and not p.is_symlink()]
        if len(receipts) != 1: raise ValueError('One completed baseline receipt required')
        receipt = read(receipts[0])
        for name in ['baseline/project.json', 'baseline/release/release.json',
                     'baseline/release/baseline.input.dill', 'baseline/release/baseline.aot.dill']:
            file = archive / name
            if not file.is_file() or file.is_symlink(): raise ValueError('Incomplete baseline archive: ' + name)
        if (read(archive / 'baseline/project.json')['gitCommit'] != receipt['gitCommit'] or
                read(archive / 'baseline/release/release.json')['baselineId'] != receipt['baselineId']):
            raise ValueError('Baseline receipt does not match frozen archive')
        return receipt, receipts[0].name.split('-')[0]

    def available(self, remote):
        allowed = {r['baselineId'] for r in remote['records'] if not r.get('retiredAt')}
        with self.locked():
            result = []
            for identity, row in self.rows().items():
                if identity not in allowed: continue
                archive = Path(row['archive']); self.owned(archive, allow_missing=True)
                if (archive / (row['platform'] + '-release.json')).is_file(): result.append(row)
            return result

    @contextmanager
    def in_use(self, identity):
        with self.locked():
            row = self.rows().get(identity)
            if row is None: raise ValueError('No local baseline; create a baseline before patching')
            directory = self.owned(row['archive'])
            handle = (directory / '.busy').open('a')
            try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except Exception:
                handle.close(); raise
        try: yield Path(row['archive'])
        finally: handle.close()

    def prune(self, remote, apply=False):
        # The service is authoritative. Never infer retirement from version
        # strings, local timestamps or a missing/offline server response.
        retired = {r['baselineId'] for r in remote['records'] if r.get('retiredAt') and not r.get('inUse')}
        with self.locked():
            rows = self.rows(); planned = []
            for identity, row in list(rows.items()):
                if identity not in retired: continue
                directory = self.owned(row['archive'], allow_missing=True)
                if not directory.exists():
                    if apply and remote.get('enabled') is True:
                        del rows[identity]; save(self.index, rows)
                    continue
                with (directory / '.busy').open('a') as handle:
                    try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError: continue
                    planned.append({'baselineId': identity, 'directory': str(directory)})
                    if apply:
                        if remote.get('enabled') is not True:
                            raise ValueError('Remote retention disabled; deletion refused')
                        shutil.rmtree(directory)
                        del rows[identity]
                        save(self.index, rows)
            return planned


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['allocate', 'record', 'list', 'prune'])
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--server-state', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.apply and args.action != 'prune': parser.error('--apply only supports prune')
    catalogue = Catalogue(args.root)
    if args.action == 'allocate': result = str(catalogue.allocate())
    else:
        if not args.server_state: parser.error('--server-state required; use authenticated retention API response')
        remote = read(args.server_state)
        if args.action == 'record':
            if not args.archive: parser.error('--archive required')
            result = catalogue.record(args.archive, remote)
        elif args.action == 'list': result = catalogue.available(remote)
        else: result = catalogue.prune(remote, args.apply)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try: main()
    except (ValueError, OSError, KeyError) as error: sys.exit('ERROR: ' + str(error))
