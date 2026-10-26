"""Locate immutable Engine artifacts from the App's resolved runtime package."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
from urllib.parse import unquote, urljoin, urlparse

FLUTTER = '00b0c91f06209d9e4a41f71b7a512d6eb3b9c694'
ENGINE = '42d3d75a56efe1a2e9902f52dc8006099c45d937'
DART = 'c70f78e7d682c158c15ca0c26c729b3ccb932284'


def _inside(root, name):
    if not isinstance(name, str) or not name or '\\' in name:
        raise ValueError('Invalid Engine artifact path')
    parts = PurePosixPath(name)
    if parts.is_absolute() or '..' in parts.parts:
        raise ValueError('Engine artifact escapes bundle')
    path = root.joinpath(*parts.parts)
    if any(p.is_symlink() for p in [path, *path.parents] if p != root and root in p.parents):
        raise ValueError('Engine artifact symlinks are unsupported')
    if root.resolve() not in path.resolve().parents:
        raise ValueError('Engine artifact escapes bundle')
    return path


def verify(manifest_path, target):
    manifest_path = Path(manifest_path)
    if manifest_path.is_symlink():
        raise ValueError('Engine manifest must not be a symlink')
    data = json.loads(manifest_path.read_text())
    if (data.get('schemaVersion') != 1 or data.get('flutterRevision') != FLUTTER or
            data.get('engineRevision') != ENGINE or data.get('dartRevision') != DART or
            data.get('host') != 'darwin-arm64' or platform.system() != 'Darwin' or platform.machine() != 'arm64'):
        raise ValueError('Unsupported Engine bundle revision or build host')
    if target not in ('android', 'ios'):
        raise ValueError('Unsupported Engine target')
    entry = data['targets'][target]
    if entry.get('abi') != 'arm64' or entry.get('mode') != 'release' or entry.get('dynamicModules') is not True:
        raise ValueError('Engine requires arm64 Release dynamic modules')
    root = manifest_path.parent
    records = data['files']
    if not isinstance(records, dict) or not records:
        raise ValueError('Empty Engine file manifest')
    actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file() or p.is_symlink()}
    if actual != set(records) | {manifest_path.name}:
        raise ValueError('Engine bundle contains missing or unlisted files')
    required = [entry['generator'], entry['engine'], entry['args']]
    if not all(name in records for name in required):
        raise ValueError('Engine manifest omits required artifacts')
    # Verify every resource, not only the main binary: framework resources and
    # licenses are part of the immutable distribution too.
    for name, record in records.items():
        path = _inside(root, name)
        if not path.is_file() or path.stat().st_size != record['size']:
            raise ValueError('Engine artifact size mismatch: ' + name)
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else _digest(stream)
        if digest != record['sha256']:
            raise ValueError('Engine artifact hash mismatch: ' + name)
        if record.get('executable') and not os.access(path, os.X_OK):
            raise ValueError('Engine tool is not executable: ' + name)
    generator = _inside(root, entry['generator'])
    build = generator.parent.parent
    engine = build / ('Flutter.framework/Flutter' if target == 'ios' else 'lib.stripped/libflutter.so')
    if engine != _inside(root, entry['engine']) or build / 'args.gn' != _inside(root, entry['args']):
        raise ValueError('Engine bundle layout does not match its paired generator')
    return {'GEN_SNAPSHOT': str(generator.resolve()), 'HOTFIX_ENGINE_MANIFEST': str(manifest_path.resolve())}


def _digest(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        digest.update(block)
    return digest.hexdigest()


def from_project(project, target):
    config = Path(project).resolve() / '.dart_tool/package_config.json'
    if not config.is_file():
        return None
    packages = json.loads(config.read_text())['packages']
    matches = [p for p in packages if p.get('name') == 'patch_runtime']
    if not matches:
        return None  # Legacy projects continue using their explicit toolchain.
    if len(matches) != 1:
        raise ValueError('Ambiguous patch_runtime package')
    uri = urlparse(urljoin(config.as_uri(), matches[0]['rootUri']))
    if uri.scheme != 'file' or uri.netloc not in ('', 'localhost'):
        raise ValueError('Runtime package must resolve to a local Pub checkout')
    package = Path(unquote(uri.path)).resolve()
    selection = package / 'engine/current.json'
    if selection.is_symlink():
        raise ValueError('Engine selection must not be a symlink')
    if not selection.is_file():
        return None  # patch_runtime 0.1.0 contains no Engine distribution.
    manifest = _inside(package / 'engine', json.loads(selection.read_text())['manifest'])
    return verify(manifest, target)
