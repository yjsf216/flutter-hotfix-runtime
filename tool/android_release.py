"""Android APK + frozen Git baseline, using existing compiler and Gradle signing.

No Git mutation, device installation or publication is performed here.
Only the pinned arm64 APK pipeline is supported; successful archives contain
android-release.json, written last. Failed outputs must never be distributed.
"""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def run(args, cwd=None, capture=False, env=None):
    return subprocess.run([str(x) for x in args], cwd=cwd, env=env,
                          check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def digest(path):
    result = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def head(project):
    require(not run(['git', 'status', '--porcelain', '--untracked-files=all'],
                    project, True).strip(), 'Commit pending files before building')
    require(Path(run(['git', 'rev-parse', '--show-toplevel'], project, True).strip()).resolve()
            == project, 'Project must be the Git repository root')
    return run(['git', 'rev-parse', 'HEAD'], project, True).strip()


def cli(*args):
    run(['sh', ROOT / 'tool/hotfix', *args])


def apk_info(apk, build_tools):
    info = run([build_tools / 'aapt', 'dump', 'badging', apk], capture=True)
    match = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", info)
    require(match is not None, 'Cannot read APK identity')
    signature = run([build_tools / 'apksigner', 'verify', '--print-certs', apk], capture=True)
    # Build-tools 37 prefixes scheme-specific signers with "V2 Signer:".
    # Only signer certificates count; never mistake a source stamp for one.
    certs = sorted({value.lower() for value in re.findall(
        r'^(?:Signer #\d+|V[1-4](?:\.\d+)? Signer:)\s+certificate SHA-256 digest:\s+([a-fA-F0-9]{64})\s*$',
        signature, re.M)})
    require(bool(certs), 'APK has no verified signer')
    return {'appId': match[1], 'release': f'{match[3]}+{match[2]}', 'certificates': certs}


def verify_libs(apk, expected):
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), 'Duplicate APK entries')
        require('lib/arm64-v8a/libpatch_store_io.so' in names, 'Native hotfix store missing')
        require(not any(n.startswith('lib/') and not n.startswith('lib/arm64-v8a/')
                        for n in names), 'Only arm64 APKs are supported')
        for name, value in expected.items():
            require(hashlib.sha256(archive.read('lib/arm64-v8a/' + name)).hexdigest() == value,
                    f'APK does not contain frozen {name}')


def init_script():
    # Properties are passed as arguments, never interpolated into Groovy source.
    return '''gradle.projectsEvaluated {
    def app = gradle.rootProject.findProject(':app')
    if (app == null) return
    def variant = app.property('hotfixVariant')
    app.tasks.named('strip' + variant.capitalize() + 'DebugSymbols').configure {
        outputs.upToDateWhen { false }
        doLast {
            def base = new File(app.buildDir, 'intermediates/stripped_native_libs/' + variant)
            def candidates = [new File(base, 'out/lib/arm64-v8a'),
                new File(base, 'strip' + variant.capitalize() + 'DebugSymbols/out/lib/arm64-v8a')].findAll { it.isDirectory() }
            if (candidates.size() != 1) throw new GradleException('Missing or ambiguous arm64 strip output')
            def dest = candidates[0]
            // CMake/dependencies can contribute other ABIs despite Flutter's target.
            // Only remove generated strip outputs, never source/native inputs.
            dest.parentFile.listFiles().findAll { it.isDirectory() && it.name != 'arm64-v8a' }.each { app.delete(it) }
            ['libapp.so': 'hotfixAot', 'libflutter.so': 'hotfixEngine'].each { name, prop ->
                def source = new File(app.property(prop))
                if (!source.isFile()) throw new GradleException('Missing ' + prop)
                java.nio.file.Files.copy(source.toPath(), new File(dest, name).toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
            }
        }
    }
}
'''


def release(config_path, output, resume=False):
    config_path = config_path.resolve()
    config = read(config_path)
    project = (config_path.parent / config['project']).resolve()
    commit = head(project)
    require(config['platform'] == 'android', 'Android only')
    flavor = config['androidFlavor']
    require(re.fullmatch(r'[a-z][A-Za-z0-9]*', flavor) is not None, 'Explicit Android flavor required')
    defines = config.get('dartDefines', {})
    require(isinstance(defines, dict) and all(isinstance(k, str) and isinstance(v, str)
            and k and not k.startswith(('dart.', 'flutter.', 'HOTFIX_'))
            for k, v in defines.items()), 'Invalid or reserved dartDefines')
    flutter = Path(os.environ['FLUTTER_SDK']).resolve()
    generator = Path(os.environ['GEN_SNAPSHOT']).resolve()
    engine = generator.parent.parent / 'lib.stripped/libflutter.so'
    build_tools = Path(os.environ['ANDROID_BUILD_TOOLS']).resolve()
    require(engine.is_file(), 'Matching custom libflutter.so missing')
    require(not (output / 'android-release.json').exists(), 'Completed archives are immutable')
    require(output.is_dir() if resume else not output.exists(), 'Use fresh output, or explicit --resume-packaging')
    require('+' in config['release'], 'release must include versionName+versionCode')
    version, code = config['release'].rsplit('+', 1)
    require(code.isdigit(), 'Invalid versionCode')
    # Keep pubspec as the version authority. Flutter itself parses the YAML.
    version_line = re.search(r'^version:\s*[\x27\x22]?([^\s\x27\x22#]+)',
                             (project / 'pubspec.yaml').read_text(), re.M)
    require(version_line and version_line[1] == config['release'], 'Config release differs from pubspec')
    if not resume:
        output.mkdir(parents=True)
    env = {**os.environ, 'ORG_GRADLE_PROJECT_hotfixRuntime': 'true'}
    # Lock is scoped to this checkout. Other build entrypoints must not run concurrently.
    with open(project / '.git/hotfix-build.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not resume:
            run([flutter / 'bin/flutter', 'build', 'apk', '--release', '--no-pub',
                 '--target-platform', 'android-arm64', '--flavor', flavor,
                 '--build-name', version, '--build-number', code,
                 *['--dart-define=' + k + '=' + v for k, v in defines.items()]], project, env=env)
        require(head(project) == commit, 'Build changed tracked/untracked source')
        native = project / f'build/app/outputs/flutter-apk/app-{flavor}-release.apk'
        original = output / 'native.apk'
        if not resume:
            shutil.copyfile(native, original)
        original_info = apk_info(original, build_tools)
        require(original_info['appId'] == config['appId'] and original_info['release'] == config['release'],
                'Native APK identity differs from configuration')
        baseline = output / 'baseline'
        if not resume:
            cli('release-git', config_path, baseline)
        metadata = read(baseline / 'project.json')
        require(metadata['gitCommit'] == commit, 'Baseline Git mismatch')
        require(metadata['generatorSha256'] == digest(generator), 'Generator changed')
        for key, value in config.items():
            if key != 'project':
                require(metadata.get(key) == value, 'Baseline configuration changed: ' + key)
        for relative, expected in metadata['sources'].items():
            require(digest(project / relative) == expected, 'Baseline source changed: ' + relative)
        variant = flavor + 'Release'
        script = output / 'package.init.gradle'
        script.write_text(init_script())
        libs = {'libapp.so': digest(baseline / 'libapp.so'), 'libflutter.so': digest(engine)}
        strip_root = project / f'build/app/intermediates/stripped_native_libs/{variant}'
        stripped_dirs = [strip_root / 'out/lib/arm64-v8a',
                         strip_root / f'strip{variant[0].upper() + variant[1:]}DebugSymbols/out/lib/arm64-v8a']
        try:
            run([project / 'android/gradlew', '-p', project / 'android', '--init-script', script,
                 ':app:assemble' + variant[0].upper() + variant[1:], '-PhotfixRuntime=true',
                 '-Ptarget-platform=android-arm64', '-PhotfixVariant=' + variant,
                 '-PhotfixAot=' + str(baseline / 'libapp.so'), '-PhotfixEngine=' + str(engine),
                 '-Pdart-defines=' + ','.join(base64.b64encode((k + '=' + v).encode()).decode()
                                             for k, v in defines.items())], project, env=env)
            packaged = project / f'build/app/outputs/apk/{flavor}/release/app-{flavor}-release.apk'
            apk = output / 'app.apk'
            shutil.copyfile(packaged, apk)
            verify_libs(apk, libs)
            require(apk_info(apk, build_tools) == original_info, 'Packaged identity/signature changed')
            require(head(project) == commit, 'Git changed during packaging')
            # Success marker is written last; an interrupted archive cannot be patched.
            write(output / 'android-release.json', {
                'schemaVersion': 1, **original_info, 'gitCommit': commit,
                'baselineId': read(baseline / 'release/release.json')['baselineId'],
                'apkSha256': digest(apk), 'libraries': libs,
                'flutterSdk': str(flutter), 'generatorSha256': digest(generator),
                'publicKeySha256': digest(Path(os.environ['HOTFIX_PUBLIC_KEY_FILE'])),
                'config': config,
            })
            print('PASS: Android archive verified:', output, flush=True)
        finally:
            # Avoid leaving custom native objects in the normal build intermediates.
            with zipfile.ZipFile(original) as archive:
                for stripped in stripped_dirs:
                    for name in libs:
                        target = stripped / name
                        if target.is_file():
                            target.write_bytes(archive.read('lib/arm64-v8a/' + name))


def patch(archive, ref, output, keys, patch_id):
    receipt = read(archive / 'android-release.json')
    require(receipt['schemaVersion'] == 1, 'Unsupported archive schema')
    require(digest(archive / 'app.apk') == receipt['apkSha256'], 'Archived APK was modified')
    baseline = archive / 'baseline'
    require(read(baseline / 'project.json')['gitCommit'] == receipt['gitCommit'] and
            read(baseline / 'release/release.json')['baselineId'] == receipt['baselineId'],
            'Archive/baseline mismatch')
    verify_libs(archive / 'app.apk', receipt['libraries'])
    cli('patch-git', baseline, ref, output)
    cli('sign', baseline, output, keys, patch_id)
    print('PASS: signed patch ready for test and explicit publication:', output, flush=True)


if __name__ == '__main__':
    try:
        if sys.argv[1:2] == ['release-android'] and (len(sys.argv) == 4 or
                len(sys.argv) == 5 and sys.argv[4] == '--resume-packaging'):
            release(Path(sys.argv[2]), Path(sys.argv[3]).resolve(), resume=len(sys.argv) == 5)
        elif len(sys.argv) == 7 and sys.argv[1] == 'patch-android':
            patch(Path(sys.argv[2]).resolve(), sys.argv[3], Path(sys.argv[4]).resolve(),
                  Path(sys.argv[5]).resolve(), sys.argv[6])
        else:
            raise ValueError('release-android CONFIG OUTPUT | patch-android ARCHIVE REF OUTPUT KEY_DIR PATCH_ID')
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit('ERROR: ' + str(error))
