"""Run: python3 -B tool/android_release_check.py (no SDK/device needed)."""
import hashlib
import os
from pathlib import Path
import tempfile
import zipfile
from unittest.mock import patch
import android_release as build


def rejects(action):
    try:
        action()
    except (ValueError, FileNotFoundError):
        return
    raise AssertionError('Unsafe input accepted')


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    apk = root / 'app.apk'
    expected = {'libapp.so': hashlib.sha256(b'aot').hexdigest()}
    with zipfile.ZipFile(apk, 'w') as archive:
        archive.writestr('lib/arm64-v8a/libapp.so', b'aot')
        archive.writestr('lib/arm64-v8a/libpatch_store_io.so', b'native')
    build.verify_libs(apk, expected)
    rejects(lambda: build.verify_libs(apk, {'libapp.so': 'wrong'}))
    # A missing completion marker must fail before invoking the compiler.
    with patch.object(build, 'cli', side_effect=AssertionError('compiler invoked')):
        rejects(lambda: build.patch(root, 'HEAD', root / 'patch', root, 'p1'))
        build.write(root / 'android-release.json', {'schemaVersion': 1, 'apkSha256': 'wrong'})
        rejects(lambda: build.patch(root, 'HEAD', root / 'patch', root, 'p1'))
    with zipfile.ZipFile(apk, 'a') as archive:
        archive.writestr('lib/x86/libapp.so', b'wrong architecture')
    rejects(lambda: build.verify_libs(apk, expected))
    with patch.object(build, 'run', side_effect=[
        "package: name='example.app' versionCode='12' versionName='1.2'\n",
        'Signer #1 certificate SHA-256 digest: ' + 'a' * 64 + '\n',
    ]):
        assert build.apk_info(apk, root) == {
            'appId': 'example.app', 'release': '1.2+12', 'certificates': ['a' * 64]}
    with patch.object(build, 'run', side_effect=[
        "package: name='example.app' versionCode='12' versionName='1.2'\n",
        'V2 Signer: certificate SHA-256 digest: ' + 'b' * 64 + '\n' +
        'V3 Signer: certificate SHA-256 digest: ' + 'b' * 64 + '\n',
    ]):
        assert build.apk_info(apk, root)['certificates'] == ['b' * 64]
    with patch.object(build, 'run', side_effect=[
        "package: name='example.app' versionCode='12' versionName='1.2'\n",
        'Source Stamp Signer certificate SHA-256 digest: ' + 'c' * 64 + '\n',
    ]):
        rejects(lambda: build.apk_info(apk, root))
    assert 'hotfixAot' in build.init_script()
    assert "it.name != 'arm64-v8a'" in build.init_script()
    # Explicit packaging retry cannot overwrite completed releases or accept
    # a changed Git baseline. Mock only external tools; execute the real guards.
    config = {'project': '.', 'platform': 'android', 'androidFlavor': 'main64',
              'appId': 'example.app', 'release': '1.2+12'}
    build.write(root / 'config.json', config)
    (root / 'pubspec.yaml').write_text('version: 1.2+12\n')
    (root / '.git').mkdir()
    engine = root / 'engine/lib.stripped/libflutter.so'
    engine.parent.mkdir(parents=True)
    engine.write_bytes(b'engine')
    generator = root / 'engine/artifacts_arm64/gen_snapshot'
    generator.parent.mkdir()
    generator.write_bytes(b'generator')
    pending = root / 'pending'
    (pending / 'baseline').mkdir(parents=True)
    build.write(pending / 'baseline/project.json', {'gitCommit': 'another-commit'})
    with patch.dict(os.environ, {'FLUTTER_SDK': str(root),
                    'GEN_SNAPSHOT': str(generator), 'ANDROID_BUILD_TOOLS': str(root)}), \
         patch.object(build, 'head', return_value='current-commit'), \
         patch.object(build, 'apk_info', return_value={'appId': 'example.app', 'release': '1.2+12'}), \
         patch.object(build, 'cli', side_effect=AssertionError('compiler invoked')):
        rejects(lambda: build.release(root / 'config.json', root, resume=True))
        rejects(lambda: build.release(root / 'config.json', root / 'missing', resume=True))
        rejects(lambda: build.release(root / 'config.json', pending, resume=True))
print('PASS: APK identity, exact AOT bytes, ABI and incomplete/tampered archive guards')
