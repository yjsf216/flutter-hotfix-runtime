"""Signed arm64 Runner archive with frozen AOT; no device or publication access."""
import fcntl
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import zipfile

from android_release import ROOT, cli, digest, head, read, require, run, write
from project_config import native_options, resolve_config
import engine_bundle


def sections(path):
    data = Path(path).read_bytes()
    require(len(data) >= 32 and struct.unpack_from('<I', data)[0] == 0xfeedfacf,
            'Expected thin arm64 Mach-O')
    require(struct.unpack_from('<I', data, 4)[0] == 0x100000c, 'Expected arm64')
    count = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    result = {}
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        require(size >= 8 and offset + size <= len(data), 'Invalid Mach-O command')
        if command == 0x19:
            nsects = struct.unpack_from('<I', data, offset + 64)[0]
            require(72 + nsects * 80 <= size, 'Invalid Mach-O sections')
            for index in range(nsects):
                section = offset + 72 + index * 80
                name = data[section:section + 32].hex()
                length, start = struct.unpack_from('<QI', data, section + 40)
                flags = struct.unpack_from('<I', data, section + 64)[0] & 0xff
                if flags in (1, 0xc, 0x12):  # zero-fill, not file-backed
                    continue
                require(start + length <= len(data), 'Invalid section bounds')
                result[name] = hashlib.sha256(data[start:start + length]).hexdigest()
        offset += size
    require(result, 'No Mach-O sections')
    return result


def files(root):
    return {str(p.relative_to(root)): digest(p) for p in root.rglob('*') if p.is_file()}


def verify(archive, receipt):
    require(digest(archive / 'app.ipa') == receipt['ipaSha256'], 'Archived IPA modified')
    with zipfile.ZipFile(archive / 'app.ipa') as bundle:
        names = bundle.namelist()
        require(len(names) == len(set(names)), 'Duplicate IPA entries')
        expected = receipt['files']
        require(set(names) == set(expected), 'IPA entries changed')
        for name, sha in expected.items():
            require(hashlib.sha256(bundle.read(name)).hexdigest() == sha, 'IPA content changed: ' + name)


def release(config_path, output, resume=False):
    config_path = config_path.resolve()
    config = read(config_path)
    require(config['platform'] == 'ios', 'iOS only')
    project = (config_path.parent / config['project']).resolve()
    commit = head(project)
    require(not (output / 'ios-release.json').exists(), 'Completed archives are immutable')
    require(output.is_dir() if resume else not output.exists(), 'Use fresh output, or explicit --resume-packaging')
    bundle = engine_bundle.from_project(project, 'ios')
    if bundle:
        os.environ.update(bundle)
    config = resolve_config(config, project)
    native_config = native_options(config)
    require(re.fullmatch(r'[A-Z0-9]{10}', native_config['team']), 'Explicit iOS signing Team required')
    require(native_config.get('scheme') == 'Runner', 'MVP supports standard Runner scheme')
    minimum = native_config.get('minimumVersion', '15.0')
    require(re.fullmatch(r'\d+\.\d+', minimum), 'Invalid deployment target')
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+', config['release']), 'Explicit iOS version+build required')
    version, code = config['release'].split('+')
    version_line = re.search(r'^version:\s*[\x27\x22]?([^\s\x27\x22#]+)', (project / 'pubspec.yaml').read_text(), re.M)
    require(version_line and version_line[1] == config['release'], 'Config release differs from pubspec')
    defines = config.get('dartDefines', {})
    native_settings = ['MARKETING_VERSION=' + version, 'CURRENT_PROJECT_VERSION=' + code,
                       'IPHONEOS_DEPLOYMENT_TARGET=' + minimum]
    if native_config.get('infoPlist'):
        plist = Path(native_config['infoPlist'])
        require(not plist.is_absolute() and '..' not in plist.parts and (project / 'ios' / plist).is_file(),
                'native.infoPlist must be an existing path inside ios/')
        require('$(HOTFIX_RUNNER_INFO_PLIST)' in (project / 'ios/Runner.xcodeproj/project.pbxproj').read_text(),
                'Run ios_integrate.rb to scope custom Info.plist to Runner, not Pods')
        native_settings.append('HOTFIX_RUNNER_INFO_PLIST=' + str(plist))
    require(isinstance(defines, dict) and all(isinstance(k, str) and isinstance(v, str) and k and
            not k.startswith(('HOTFIX_', 'dart.', 'flutter.')) for k, v in defines.items()), 'Invalid defines')
    flutter = Path(os.environ['FLUTTER_SDK'])
    generator = Path(os.environ['GEN_SNAPSHOT']).resolve()
    engine = generator.parent.parent / 'Flutter.framework'
    require((engine / 'Flutter').is_file(), 'Matching iOS DDM Engine missing')
    output.mkdir(parents=True, exist_ok=resume)
    config = {**config, 'project': str(project)}
    config_path = output / 'resolved-config.json'
    if resume:
        require(read(config_path) == config, 'Resolved native build configuration changed')
    else:
        write(config_path, config)
    git_directory = Path(run(['git', 'rev-parse', '--absolute-git-dir'], project, True).strip())
    with open(git_directory / 'hotfix-build.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not resume:
            run([flutter / 'bin/flutter', 'build', 'ios', '--release', '--no-pub', '--no-codesign',
                 '--target', config['entry'], '--build-name', version, '--build-number', code,
                 *['--dart-define=' + k + '=' + v for k, v in defines.items()]], project)
            run(['xcodebuild', '-workspace', project / 'ios/Runner.xcworkspace', '-scheme', 'Runner',
                 '-configuration', 'Release', '-destination', 'generic/platform=iOS',
                 '-derivedDataPath', output / 'native-build', '-allowProvisioningUpdates',
                 'DEVELOPMENT_TEAM=' + native_config['team'], 'CODE_SIGN_STYLE=Automatic',
                 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', *native_settings, 'build'], project)
        require(head(project) == commit, 'Native build modified source; inspect and commit generated native inputs')
        native = output / 'native-build/Build/Products/Release-iphoneos/Runner.app'
        require(native.is_dir(), 'Runner.app missing')
        if os.environ.get('HOTFIX_CI_TRIM_BUILD_CACHE') == 'true':
            require(not run(['git', 'ls-files', '--', 'build'], project, True).strip(), 'Tracked build directory')
            for temporary in [project / 'build', output / 'native-build/Build/Intermediates.noindex',
                              output / 'native-build/ModuleCache.noindex', output / 'native-build/Index.noindex']:
                require(not temporary.is_symlink(), 'Refuse linked build cache')
                if temporary.is_dir(): shutil.rmtree(temporary)
        info = plistlib.loads((native / 'Info.plist').read_bytes())
        require(info['CFBundleIdentifier'] == config['appId'] and
                info['CFBundleShortVersionString'] + '+' + info['CFBundleVersion'] == config['release'], 'Native identity mismatch')
        profile = run(['security', 'cms', '-D', '-i', native / 'embedded.mobileprovision'], capture=True)
        provision = plistlib.loads(profile.encode())
        require(native_config['team'] in provision['TeamIdentifier'], 'Signing Team mismatch')
        cert_prefix = output / 'signing-cert-'
        run(['codesign', '-d', '--extract-certificates=' + str(cert_prefix), native])
        certificate = Path(str(cert_prefix) + '0')
        identity = hashlib.sha1(certificate.read_bytes()).hexdigest()
        entitlements = run(['codesign', '-d', '--entitlements', ':-', native], capture=True)
        entitlement_file = output / 'entitlements.plist'
        entitlement_file.write_bytes(plistlib.dumps(plistlib.loads(entitlements.encode())))
        baseline = output / 'baseline'
        if not resume or not (baseline / 'project.json').is_file():
            if resume and baseline.exists():
                require(not baseline.is_symlink(), 'Refuse linked incomplete baseline')
                shutil.rmtree(baseline)
            cli('release-git', config_path, baseline)
        metadata = read(baseline / 'project.json')
        require(metadata['gitCommit'] == commit and metadata['generatorSha256'] == digest(generator), 'Frozen baseline mismatch')
        for relative, sha in metadata['sources'].items():
            require(digest(project / relative) == sha, 'Frozen input changed: ' + relative)
        payload = output / 'Payload'
        if resume:
            require(not payload.is_symlink(), 'Refuse linked payload')
            if payload.is_dir(): shutil.rmtree(payload)
            previous_ipa = output / 'app.ipa'
            require(not previous_ipa.is_symlink(), 'Refuse linked IPA')
            if previous_ipa.exists(): previous_ipa.unlink()
        payload.mkdir()
        app = payload / 'Runner.app'
        shutil.copytree(native, app)
        original_files = files(app)
        app_framework = app / 'Frameworks/App.framework'
        require((app_framework / 'flutter_assets').is_dir(), 'Flutter assets missing')
        sdk = run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], capture=True).strip()
        run(['xcrun', 'clang', '-target', 'arm64-apple-ios' + minimum, '-isysroot', sdk,
             '-dynamiclib', '-Wl,-install_name,@rpath/App.framework/App',
             baseline / 'snapshot.S', '-o', app_framework / 'App'])
        target_engine = app / 'Frameworks/Flutter.framework'
        shutil.rmtree(target_engine)  # Only the freshly copied archive's generated framework.
        shutil.copytree(engine, target_engine)
        frozen_sections = {'App': sections(app_framework / 'App'), 'Flutter': sections(engine / 'Flutter')}
        host_sections = sections(native / info['CFBundleExecutable'])
        for framework in (app_framework, target_engine):
            run(['codesign', '--force', '--sign', identity, '--timestamp=none', framework])
        run(['codesign', '--force', '--sign', identity, '--entitlements', entitlement_file, '--timestamp=none', app])
        run(['codesign', '--verify', '--deep', '--strict', app])
        for name, expected in frozen_sections.items():
            require(sections(app / f'Frameworks/{name}.framework/{name}') == expected, 'Signing changed frozen sections')
        require(sections(app / info['CFBundleExecutable']) == host_sections, 'Signing changed native executable sections')
        packaged_files = files(app)
        def keep(name):
            return not name.startswith(('Frameworks/Flutter.framework/', '_CodeSignature/')) and name not in (
                info['CFBundleExecutable'], 'Frameworks/App.framework/App', 'Frameworks/App.framework/_CodeSignature/CodeResources')
        require({k: v for k, v in original_files.items() if keep(k)} ==
                {k: v for k, v in packaged_files.items() if keep(k)}, 'Native resources/assets/plugins changed')
        symbols = run(['xcrun', 'nm', '-gU', app / info['CFBundleExecutable']], capture=True)
        require(all('_psio_' + name in symbols for name in ('set_app_base', 'open_root', 'close', 'lock', 'unlock', 'read', 'replace', 'free')), 'Native store exports missing')
        ipa = output / 'app.ipa'
        with zipfile.ZipFile(ipa, 'x', compression=zipfile.ZIP_DEFLATED) as ipa_zip:
            for file in sorted(app.rglob('*')):
                if file.is_file():
                    ipa_zip.write(file, str(file.relative_to(output)))
        receipt = {'schemaVersion': 1, 'platform': 'ios', 'appId': config['appId'], 'release': config['release'],
                   'gitCommit': commit, 'baselineId': read(baseline / 'release/release.json')['baselineId'],
                   'ipaSha256': digest(ipa), 'teamId': native_config['team'], 'certificateSha256': digest(certificate),
                   'generatorSha256': digest(generator), 'sections': frozen_sections,
                   'engineBundle': ({'version': read(bundle['HOTFIX_ENGINE_MANIFEST'])['version'],
                                     'manifestSha256': digest(bundle['HOTFIX_ENGINE_MANIFEST'])} if bundle else None),
                   'files': {'Payload/Runner.app/' + k: v for k, v in packaged_files.items()},
                   'publicKeySha256': digest(Path(os.environ['HOTFIX_PUBLIC_KEY_FILE'])), 'config': config}
        verify(output, receipt)
        require(head(project) == commit, 'Git changed during packaging')
        write(output / 'ios-release.json', receipt)
        print('PASS: signed iOS archive verified:', ipa, flush=True)


def patch(archive, ref, output, keys, patch_id):
    receipt = read(archive / 'ios-release.json')
    require(receipt['schemaVersion'] == 1 and receipt['platform'] == 'ios', 'Invalid iOS archive')
    verify(archive, receipt)
    baseline = archive / 'baseline'
    require(read(baseline / 'project.json')['gitCommit'] == receipt['gitCommit'] and
            read(baseline / 'release/release.json')['baselineId'] == receipt['baselineId'], 'Archive/baseline mismatch')
    cli('patch-git', baseline, ref, output)
    cli('sign', baseline, output, keys, patch_id)
    print('PASS: signed iOS patch ready for explicit publication:', output, flush=True)


if __name__ == '__main__':
    try:
        if sys.argv[1:2] == ['release-ios'] and (len(sys.argv) == 4 or
                len(sys.argv) == 5 and sys.argv[4] == '--resume-packaging'):
            release(Path(sys.argv[2]), Path(sys.argv[3]).resolve(), resume=len(sys.argv) == 5)
        elif len(sys.argv) == 7 and sys.argv[1] == 'patch-ios':
            patch(Path(sys.argv[2]).resolve(), sys.argv[3], Path(sys.argv[4]).resolve(), Path(sys.argv[5]).resolve(), sys.argv[6])
        else:
            raise ValueError('release-ios CONFIG OUTPUT | patch-ios ARCHIVE REF OUTPUT KEY_DIR PATCH_ID')
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit('ERROR: ' + str(error))
