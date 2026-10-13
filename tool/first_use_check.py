"""Fresh Runtime clone + new Android app + empty Pub/Gradle caches; no devices."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import Request, urlopen

import app_cli as app
import toolchain


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in toolchain.PATH_OPTIONS:
        parser.add_argument('--' + option.replace('_', '-'))
    parser.add_argument('--toolchain-profile', type=Path)
    args = parser.parse_args()
    saved = app.read(args.toolchain_profile).get('environment', {}) if args.toolchain_profile else {}
    paths = toolchain.discover(args, saved)
    app.validate_tools(paths)
    os.umask(0o077)
    (app.ROOT / 'work').mkdir(exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix='first-use-', dir=app.ROOT / 'work'))
    runtime, project = workspace / 'runtime', workspace / 'demo'
    env = {**os.environ, **paths, 'PUB_CACHE': str(workspace / 'pub-cache'),
           'GRADLE_USER_HOME': str(workspace / 'gradle-cache')}
    env.pop('HOTFIX_PUBLISH_TOKEN', None)
    log = (workspace / 'commands.log').open('wb')
    process = None
    result = {'workspace': str(workspace), 'devicesUsed': False,
              'freshPubCache': True, 'freshGradleCache': True, 'preparedToolchainReused': True}
    print('Acceptance workspace: ' + str(workspace), flush=True)

    def run(arguments, cwd=None):
        outcome = subprocess.run([str(x) for x in arguments], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=subprocess.STDOUT)
        log.flush()
        if outcome.returncode:
            raise RuntimeError('command failed; inspect ' + str(workspace / 'commands.log'))

    def git(*arguments):
        return app.run(['git', '-C', project, *arguments], capture=True, env=env).strip()

    def free_port():
        with socket.socket() as temporary:
            temporary.bind(('127.0.0.1', 0))
            return temporary.getsockname()[1]

    management = free_port()
    delivery = free_port()
    while delivery == management:
        delivery = free_port()
    origin = f'http://127.0.0.1:{delivery}'
    console_origin = f'http://127.0.0.1:{management}'
    tool_args = [argument for option, variable in toolchain.PATH_OPTIONS.items()
                 for argument in ('--' + option.replace('_', '-'), paths[variable])]

    try:
        run(['git', 'clone', '--no-local', '--', app.ROOT, runtime])
        assert not (runtime / 'work').exists() and not (runtime / 'spikes/patch_ir_spike/.dart_tool').exists()
        run(['sh', runtime / 'tool/hotfix', 'doctor', *tool_args], workspace)
        assert not (runtime / 'work').exists(), 'doctor must not write SDK bindings'
        run([Path(paths['FLUTTER_SDK']) / 'bin/flutter', 'create', '--platforms=android', '--no-pub',
             '--org', 'dev.hotfixruntime', '--project-name', 'first_use_demo', project])
        run(['git', 'init', '-q', project])
        run(['git', '-C', project, 'config', 'user.name', 'Hotfix acceptance'])
        run(['git', '-C', project, 'config', 'user.email', 'acceptance@example.invalid'])
        test = project / 'test/widget_test.dart'
        test.write_text("import 'package:first_use_demo/main.dart';\nimport 'package:flutter_test/flutter_test.dart';\nvoid main() { testWidgets('selected title renders', (tester) async {\n const title = String.fromEnvironment('EXPECT_TITLE', defaultValue: 'Flutter Demo Home Page');\n await tester.pumpWidget(const MyApp());\n expect(find.text(title), findsOneWidget);\n expect(tester.takeException(), isNull);\n}); }\n")
        run(['sh', runtime / 'tool/hotfix', 'init', '--origin', origin, *tool_args], project)
        assert (runtime / 'work/upstream/dart-sdk').resolve() == Path(paths['DART_SDK_SOURCE'])
        run(['git', '-C', project, 'add', '.'])
        run(['git', '-C', project, 'commit', '-qm', '示例：初始化热更新发行基线'])
        baseline_commit = git('rev-parse', 'HEAD')
        launcher = project / '.hotfix/run'
        run([launcher, 'doctor'], project)
        run([Path(paths['FLUTTER_SDK']) / 'bin/flutter', 'test', '--no-pub'], project)
        print('PASS clean clone, doctor, init and baseline widget test', flush=True)
        with (workspace / 'server.log').open('wb') as output:
            process = subprocess.Popen([str(launcher), 'console', '--port', str(management), '--with-delivery'],
                                       cwd=project, env=env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 30
        while True:
            if process.poll() is not None:
                raise RuntimeError('console exited; inspect server.log')
            try:
                with urlopen(console_origin, timeout=1) as response:
                    assert b'Flutter Hotfix' in response.read()
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise RuntimeError('console startup timed out')
                time.sleep(.2)
        token = (project / '.hotfix/console/access-token').read_text().strip()

        def api(path, body=None):
            headers = {'Authorization': 'Bearer ' + token}
            if body is not None:
                headers['Content-Type'] = 'application/json'
            with urlopen(Request(console_origin + path, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None), timeout=20) as response:
                return json.load(response)

        def task(body):
            identifier = api('/api/tasks', body)['id']
            print('START ' + body['action'], flush=True)
            deadline = time.monotonic() + 1200
            while time.monotonic() < deadline:
                state = api('/api/state')
                record = next(t for t in state['tasks'] if t['id'] == identifier)
                if record['status'] == 'succeeded':
                    print('PASS ' + body['action'], flush=True)
                    return state
                if record['status'] in ('failed', 'interrupted'):
                    raise RuntimeError(record.get('error', record['status']) + '; see ' + str(project / '.hotfix/console' / (identifier + '.log')))
                time.sleep(2)
            raise RuntimeError('task timed out: ' + body['action'])

        state = task({'action': 'build', 'commit': baseline_commit})
        baseline = state['baselines'][-1]
        source = project / 'lib/main.dart'
        original = source.read_text()
        assert original.count('Flutter Demo Home Page') == 1
        source.write_text(original.replace('Flutter Demo Home Page', 'Hotfix repaired'))
        run([Path(paths['FLUTTER_SDK']) / 'bin/flutter', 'test', '--no-pub',
             '--dart-define=EXPECT_TITLE=Hotfix repaired'], project)
        run(['git', '-C', project, 'add', 'lib/main.dart'])
        run(['git', '-C', project, 'commit', '-qm', '示例：修复页面标题'])
        fix_commit = git('rev-parse', 'HEAD')
        state = task({'action': 'patch', 'baseline': baseline['id'], 'commit': fix_commit})
        candidate = state['patches'][-1]
        task({'action': 'publish', 'patch': candidate['id'], 'confirmed': True})
        with urlopen(origin + '/v1/check?baselineId=' + baseline['baselineId']) as response:
            manifest = json.load(response)['manifest']
        assert manifest['patchId'] == candidate['patchId']
        with urlopen(origin + '/v1/blobs/' + manifest['artifactSha256']) as response:
            assert hashlib.sha256(response.read()).hexdigest() == manifest['artifactSha256']
        assert api('/api/stats/' + baseline['id']) == {'eventCounts': {}, 'uniqueUsers': None}
        request = Request(console_origin + '/api/apk/' + baseline['id'], headers={'Authorization': 'Bearer ' + token})
        with urlopen(request, timeout=30) as response:
            digest = hashlib.sha256()
            for chunk in iter(lambda: response.read(1024 * 1024), b''):
                digest.update(chunk)
        assert digest.hexdigest() == baseline['apkSha256']
        task({'action': 'withdraw', 'patch': candidate['id'], 'confirmed': True})
        with urlopen(origin + '/v1/withdrawals?baselineId=' + baseline['baselineId']) as response:
            assert len(json.load(response)) == 1
        assert git('rev-parse', 'HEAD') == fix_commit and not git('status', '--porcelain')
        assert not app.run(['git', '-C', runtime, 'status', '--porcelain'], capture=True, env=env).strip()
        result.update(passed=True, baselineCommit=baseline_commit, fixCommit=fix_commit,
                      baselineId=baseline['baselineId'], patchId=candidate['patchId'],
                      managementPort=management, deliveryPort=delivery)
        print('PASS first-use build, signed delivery, download hash and withdrawal; no devices used', flush=True)
    except Exception as error:
        result.update(passed=False, error=str(error))
        raise
    finally:
        app.save(workspace / 'results.json', result)
        if process:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGINT)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        log.close()
        print('Evidence: ' + str(workspace / 'results.json'), flush=True)


if __name__ == '__main__':
    main()
