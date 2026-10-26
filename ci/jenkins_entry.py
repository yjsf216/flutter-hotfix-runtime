"""Dedicated Jenkins base/patch runner; all source changes stay in CI-owned clones."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
from urllib.parse import urlsplit

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS / 'tool'))
from android_release import run, read, require, head, digest, cli
from app_cli import app_info, save, tool_stamp
import engine_bundle
import toolchain
import upload_baseline
import upload_patch
from ci_baselines import Catalogue
from retention_client import Client


def commit(source, ref):
    require(isinstance(ref, str) and re.fullmatch(r'[a-f0-9]{40}', ref), 'Use a resolved full App commit')
    return run(['git', 'rev-parse', '--verify', '--end-of-options', ref + '^{commit}'], source, True).strip()


def source_directory(source, project, ref):
    if not project.exists():
        run(['git', 'clone', '--quiet', '--no-hardlinks', '--no-checkout', source, project])
        remote = run(['git', 'remote', 'get-url', 'origin'], source, True).strip()
        require(remote.startswith(('git@', 'https://')), 'Source must have its real Git remote')
        if remote.startswith('https://'):
            uri = urlsplit(remote)
            require(not uri.username and not uri.password, 'Do not persist credential-bearing repository URLs')
        run(['git', 'remote', 'set-url', 'origin', remote], project)
        run(['git', 'repack', '-a', '-d'], project)
    else:
        head(project)  # Never discard source changes left by a failed task.
        run(['git', 'fetch', '--quiet', '--no-tags', source, ref], project)
    run(['git', 'checkout', '--quiet', '--detach', ref], project)
    require(head(project) == ref, 'Unexpected checkout commit')


def environment(config, project, platform):
    saved = dict(config['environment'])
    args = argparse.Namespace(platform=platform, project=project)
    env = toolchain.discover(args, saved)
    failures = [c['name'] for c in toolchain.inspect(env) if not c['ok']]
    require(not failures, 'Missing toolchain inputs: ' + ', '.join(failures))
    env = {**os.environ, **env}
    env['HOTFIX_UPLOAD_TOKEN'] = Path(config['uploadTokenFile']).read_text().strip()
    env['HOTFIX_PUBLIC_KEY_FILE'] = str(Path(config['keys']) / 'public-key.txt')
    env['HOTFIX_MANIFEST_TTL_SECONDS'] = str(config.get('manifestTTLSeconds', 604800))
    return env


def baseline(args, config, catalogue, source, ref):
    directory = catalogue.allocate()
    project = directory / 'project'
    source_directory(source, project, ref)
    # Resolve dependencies once for a new base. Patch tasks never run pub get.
    preliminary = {**os.environ, **config['environment']}
    sdk = Path(preliminary['FLUTTER_SDK'])
    run([sdk / 'bin/flutter', 'pub', 'get'], project, env=preliminary)
    # Flutter regenerates desktop registrants during mobile pub get. Only these
    # generated, tracked files may be restored in our isolated clone.
    for path in ['macos/Flutter/GeneratedPluginRegistrant.swift',
                 'linux/flutter/generated_plugin_registrant.cc',
                 'linux/flutter/generated_plugins.cmake',
                 'windows/flutter/generated_plugin_registrant.cc',
                 'windows/flutter/generated_plugins.cmake']:
        if run(['git', 'ls-files', '--', path], project, True).strip():
            run(['git', 'restore', '--source=HEAD', '--worktree', '--', path], project)
    env = environment(config, project, args.platform)
    settings = read(project / ('hotfix.' + args.platform + '.json'))
    require(settings['updateOrigin'].rstrip('/') == config['origin'].rstrip('/'), 'App update origin differs from CI upload origin')
    require(settings.get('patchNumberingOrigin', '').rstrip('/') == config['origin'].rstrip('/'), 'Automatic patch numbering origin required')
    settings.update(project=str(project), release=app_info(project, env)['version'])
    generated = directory / 'config.json'; save(generated, settings)
    archive = directory / 'archive'
    os.environ.update(env)
    stamp = tool_stamp()
    cli('release-' + args.platform, generated, archive)
    require(tool_stamp() == stamp, 'Build tools changed during baseline compilation')
    receipt = read(archive / (args.platform + '-release.json'))
    require(receipt['gitCommit'] == ref, 'Baseline commit mismatch')
    save(directory / 'ci-build.json', {'toolStamp': stamp, 'sourceCommit': ref})
    upload_baseline.upload(config['origin'], archive, args.branch, ref)
    frozen = read(archive / 'baseline/project.json')
    channel = (frozen.get('dartDefines', {}).get('APP_CHANNEL') or
               frozen.get('native', {}).get('flavor') or 'default')
    client = Client(config['origin'])
    remote = client.call('/register', {'baselineId': receipt['baselineId'], 'channel': channel})
    catalogue.record(archive, remote)
    # Dedicated tags expose baseline choices through Jenkins's existing Git
    # Parameter plugin. They never alter App branches or ordinary release tags.
    tag = 'hotfix-base-' + args.platform + '-' + re.sub(r'[^A-Za-z0-9_.-]', '_', channel) + '-' + receipt['release'].replace('+', '_') + '-' + receipt['baselineId']
    run(['git', 'tag', tag, ref], project)
    run(['git', 'push', 'origin', 'refs/tags/' + tag], project)
    return {'kind': 'baseline', 'baselineId': receipt['baselineId'], 'release': receipt['release'],
            'platform': args.platform, 'channel': channel, 'sourceCommit': ref, 'baselineTag': tag,
            'managementUrl': config['origin'] + '/'}


def patch_inner(args, config, catalogue, source, ref):
    archive = Path(os.environ['HOTFIX_BASELINE_ARCHIVE']).resolve()
    directory = catalogue.owned(archive)
    receipt = read(archive / (args.platform + '-release.json'))
    require(receipt['baselineId'] == args.baseline_id, 'Wrong platform or baseline selection')
    require(read(directory / 'ci-build.json')['toolStamp'] == tool_stamp(), 'Restore the baseline-matched build tools before patching')
    project = directory / 'project'
    require(Path(read(archive / 'baseline/project.json')['project']).resolve() == project, 'Baseline workspace moved')
    source_directory(source, project, ref)
    env = environment(config, project, args.platform)
    require(app_info(project, env)['version'] == receipt['release'], 'App version changed; build a new base')
    require(digest(Path(config['keys']) / 'public-key.txt') == receipt['publicKeySha256'], 'Signing key differs from baseline')
    os.environ.update(env)
    output = directory / 'patches' / (ref[:12] + '-' + secrets.token_hex(4))
    output.parent.mkdir(exist_ok=True)
    cli('patch-' + args.platform, archive, ref, output, config['keys'], 'patch-' + output.name)
    upload_patch.upload(config['origin'], output/'manifest.json', output/'patch.bytecode')
    withdrawal = output.with_name(output.name + '-withdrawal')
    cli('policy', archive/'baseline', output, config['keys'], withdrawal, 'withdraw')
    upload_patch.upload(config['origin'], withdrawal/'manifest.json', withdrawal/'patch.bytecode')
    manifest = read(output/'manifest.json')['manifest']
    return {'kind': 'patch', 'baselineId': receipt['baselineId'], 'release': receipt['release'],
            'platform': args.platform, 'patchId': manifest['patchId'], 'patchNumber': manifest.get('patchNumber'),
            'sourceCommit': ref, 'status': 'uploaded', 'managementUrl': config['origin'] + '/'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--mode', choices=['baseline', 'patch', 'patch-inner'], required=True)
    parser.add_argument('--platform', choices=['android', 'ios'], required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--branch', required=True)
    parser.add_argument('--baseline-id', default='')
    parser.add_argument('--result', type=Path, required=True)
    args = parser.parse_args()
    config = read(args.config)
    source = args.source.resolve(); ref = commit(source, args.commit)
    require(re.fullmatch(r'[A-Za-z0-9_./-]{1,200}', args.branch), 'Invalid source branch name')
    catalogue = Catalogue(config['dataRoot'])
    if args.mode == 'patch':
        match = re.search(r'([a-f0-9]{64})$', args.baseline_id)
        require(match, 'Select a completed baseline first')
        args.baseline_id = match[1]
        # Renew the server lease while the trusted child runs. Its process group
        # is terminated if lease renewal fails; no admin/publish token is used.
        os.environ['HOTFIX_UPLOAD_TOKEN'] = Path(config['uploadTokenFile']).read_text().strip()
        command = [sys.executable, str(Path(__file__).resolve()), '--config', str(args.config.resolve()),
                   '--mode', 'patch-inner', '--platform', args.platform, '--source', str(source),
                   '--commit', ref, '--branch', args.branch, '--baseline-id', args.baseline_id,
                   '--result', str(args.result.resolve())]
        run([sys.executable, TOOLS/'ci/retention_client.py', 'patch', '--origin', config['origin'],
             '--root', config['dataRoot'], '--baseline-id', args.baseline_id, '--', *command])
        return
    result = baseline(args, config, catalogue, source, ref) if args.mode == 'baseline' else patch_inner(args, config, catalogue, source, ref)
    save(args.result, result)
    print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    try: main()
    except Exception as error:
        # Subprocess diagnostics are already emitted by the owned build tools;
        # credentials/config content must never be dumped here.
        sys.exit('Hotfix CI failed: ' + type(error).__name__ + ': ' + str(error))
