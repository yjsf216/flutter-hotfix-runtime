"""Local, single-operator console. The existing CLI remains the build authority."""
import argparse
import contextlib
import fcntl
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tool'))
import app_cli as app

ID = re.compile(r'^[a-f0-9]{24}$')
SHA = re.compile(r'^[a-f0-9]{40,64}$')


def now():
    return datetime.now(timezone.utc).isoformat()


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Console:
    def __init__(self, project, platform=None):
        self.project = project.resolve()
        project = self.project
        app.require((self.project / '.git').is_dir() and not (self.project / '.hotfix').is_symlink(),
                    '需要独立 App Git 仓库和普通 .hotfix 目录')
        self.local = app.toolchain.profile_directory(project, platform)
        self.local_relative = self.local.relative_to(project)
        self.platform_scope = self.local.name if self.local != project / '.hotfix' else None
        profile = app.read(self.local / 'local.json')
        app.require(profile.get('ready') and profile.get('project') == str(self.project),
                    '请先在 App 根目录完成 hotfix init')
        ignored = subprocess.run(['git', '-C', project, 'check-ignore', '-q', '--',
                                  str(self.local_relative / 'console/access-token')], capture_output=True)
        app.require(ignored.returncode == 0 and not app.run(
                    ['git', '-C', project, 'ls-files', '--', '.hotfix'], capture=True).strip(),
                    '.hotfix 必须完全忽略且没有被 Git 跟踪的文件，避免提交凭据和任务产物')
        self.profile = profile
        self.root = self.local / 'console'
        app.require(not self.root.is_symlink(), '管理目录不能是软链接')
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.lock = (self.root / 'server.lock').open('a')
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.token_file = self.root / 'access-token'
        app.require(not self.token_file.is_symlink(), '令牌不能是软链接')
        if not self.token_file.exists():
            with self.token_file.open('x') as stream:
                os.chmod(self.token_file, 0o600)
                stream.write(secrets.token_hex(32))
        self.token = self.token_file.read_text().strip()
        app.require(len(self.token) >= 32, '管理令牌无效')
        self.file = self.root / 'state.json'
        self.state = app.read(self.file) if self.file.exists() else {'tasks': [], 'baselines': [], 'patches': []}
        for task in self.state['tasks']:
            if task['status'] in ('running', 'queued'):
                task.update(status='interrupted', finishedAt=now())
        self.mutex = threading.RLock()
        self.active = None
        self.process = None
        self.thread = None
        self.stopping = False
        self.workspace = project.parent / ('.hotfix-console-' + self.root_id() +
                                          ('-' + self.platform_scope if self.platform_scope else ''))
        self.workspace_local = self.workspace / self.local_relative
        self.persist()

    def root_id(self):
        import hashlib
        return hashlib.sha256(str(self.project).encode()).hexdigest()[:16]

    def persist(self):
        app.save(self.file, self.state)

    def git(self, *args):
        return app.run(['git', '-C', self.workspace, *args], capture=True).strip()

    def prepare(self, task):
        if not self.workspace.exists():
            self.execute(task, ['git', 'clone', '--no-hardlinks', '--', self.project, self.workspace])
            app.save(self.workspace / '.hotfix/console-owner.json', {'project': str(self.project)})
            with (self.workspace / '.git/info/exclude').open('a') as stream:
                stream.write('\n/.hotfix/\n')
        app.require(not self.workspace.is_symlink() and
                    app.read(self.workspace / '.hotfix/console-owner.json')['project'] == str(self.project),
                    '专用构建目录不属于本后台，拒绝覆盖')
        self.execute(task, ['git', '-C', self.workspace, 'fetch', '--no-tags', 'origin'])
        # Only known local Android configuration is copied. Keystores remain at
        # operator-configured paths; arbitrary ignored files are never copied.
        for relative in ('android/local.properties', 'android/key.properties'):
            if task.get('action') == 'patch' and relative == 'android/local.properties':
                continue
            source = self.project / relative
            if source.exists():
                app.require(source.is_file() and not source.is_symlink(), 'Android 配置需要普通文件')
                destination = self.workspace / relative
                app.require(not destination.is_symlink(), '拒绝覆盖配置软链接')
                app.require(self.git('ls-files', '--', relative) == '', '签名/本地配置必须不被 Git 跟踪')
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(source.read_bytes())
                destination.chmod(0o600)
        managed = {**self.profile, 'project': str(self.workspace)}
        app.save(self.workspace_local / 'local.json', managed)

    def freeze_local_properties(self, archive, task):
        expected = app.read(archive / 'baseline/project.json')['sources'].get('android/local.properties')
        if expected is None:
            return None
        source = self.workspace / 'android/local.properties'
        app.require(source.is_file() and not source.is_symlink() and app.digest(source) == expected,
                    '构建 local.properties 与冻结输入不一致')
        destination = self.root / (task['id'] + '.inputs') / 'local.properties'
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        destination.write_bytes(source.read_bytes())
        destination.chmod(0o600)
        return {'path': str(destination), 'sha256': expected}

    def freeze_ios_inputs(self, archive, task):
        metadata = app.read(archive / 'baseline/project.json')
        if metadata.get('platform') != 'ios':
            return None
        saved = {}
        for relative, sha in metadata['sources'].items():
            if not relative.startswith('ios/') or self.git('ls-files', '--', relative):
                continue
            source = self.workspace / relative
            app.require(source.is_file() and not source.is_symlink() and app.digest(source) == sha, 'iOS 生成输入变化: ' + relative)
            destination = self.root / (task['id'] + '.inputs') / relative
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            destination.write_bytes(source.read_bytes())
            saved[relative] = {'path': str(destination), 'sha256': sha}
        return saved

    def restore_ios_inputs(self, baseline):
        metadata = app.read(Path(baseline['path']) / 'baseline/project.json')
        saved = baseline.get('iosInputs') or {}
        for relative, record in saved.items():
            parts = Path(relative).parts
            app.require(parts[0] == 'ios' and '..' not in parts and not Path(relative).is_absolute(), '无效冻结输入路径')
            source = Path(record['path'])
            destination = self.workspace / relative
            app.require(not destination.is_symlink() and not any(p.is_symlink() for p in destination.parents), '不恢复软链接输入')
            app.require(source.is_file() and not source.is_symlink() and metadata['sources'].get(relative) == record['sha256'] and app.digest(source) == record['sha256'], 'iOS 冻结输入被修改')
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(source.read_bytes())

    def restore_local_properties(self, baseline):
        expected = app.read(Path(baseline['path']) / 'baseline/project.json')['sources'].get('android/local.properties')
        if expected is None:
            return
        saved = baseline.get('localProperties')
        destination = self.workspace / 'android/local.properties'
        app.require(not destination.is_symlink(), 'local.properties 不能是软链接')
        if saved:
            source = Path(saved['path'])
            app.require(source.is_file() and not source.is_symlink() and saved['sha256'] == expected and
                        app.digest(source) == expected, '冻结的 local.properties 已被修改')
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(source.read_bytes())
        else:
            app.require(destination.is_file() and app.digest(destination) == expected,
                        '历史基线缺少匹配的 local.properties 归档；请使用原工具与构建副本或构建新基线')

    def execute(self, task, args, cwd=None, extra=None):
        env = {**os.environ, **self.profile['environment'], **(extra or {})}
        if self.platform_scope:
            env['HOTFIX_ACTIVE_PLATFORM'] = self.platform_scope
        env.pop('HOTFIX_CONSOLE_TOKEN', None)
        env['GIT_TERMINAL_PROMPT'] = '0'
        # Publish credentials are not inherited by builds/Git subprocesses.
        if not extra or 'HOTFIX_PUBLISH_TOKEN' not in extra:
            env.pop('HOTFIX_PUBLISH_TOKEN', None)
        with self.mutex:
            app.require(not self.stopping, '后台正在停止')
            process = subprocess.Popen([str(a) for a in args], cwd=cwd, env=env,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            self.process = process
        secrets_to_hide = [self.token, os.environ.get('HOTFIX_PUBLISH_TOKEN', '')]
        local_token = self.local / 'publish-token'
        if local_token.is_file():
            secrets_to_hide.append(local_token.read_text().strip())
        try:
            with (self.root / (task['id'] + '.log')).open('ab') as log:
                size = 0
                tail = bytearray()
                for line in iter(lambda: process.stdout.readline(64 * 1024), b''):
                    text = line.decode('utf-8', errors='replace')
                    for secret in secrets_to_hide:
                        if secret:
                            text = text.replace(secret, '[REDACTED]')
                    data = text.encode()
                    # Keep startup context and final diagnostics within 8 MiB.
                    head_limit = 4 * 1024 * 1024
                    remaining = max(0, head_limit - size)
                    if remaining:
                        log.write(data[:remaining])
                        log.flush()
                    tail.extend(data[remaining:])
                    if len(tail) > head_limit:
                        del tail[:-head_limit]
                    size += len(data)
                if tail:
                    if size > 8 * 1024 * 1024:
                        log.write(b'\n[intermediate build output omitted; final diagnostics follow]\n')
                    log.write(tail)
            app.require(process.wait() == 0, '命令失败，请查看构建日志')
        finally:
            if process.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            process.stdout.close()
            with self.mutex:
                if self.process is process:
                    self.process = None

    def prepare_dependencies(self, task):
        source = self.project / 'pubspec.lock'
        destination = self.workspace / 'pubspec.lock'
        if source.exists() and not self.git('ls-files', '--', 'pubspec.lock'):
            app.require(source.is_file() and not source.is_symlink() and not destination.is_symlink(),
                        '依赖锁文件必须是普通文件')
            # An untracked local lock is still a build input; preserve its
            # resolved dependencies instead of upgrading them in a fresh clone.
            destination.write_bytes(source.read_bytes())
        desktop = ('macos/Flutter/GeneratedPluginRegistrant.swift',
                   'linux/flutter/generated_plugin_registrant.cc', 'linux/flutter/generated_plugin_registrant.h',
                   'linux/flutter/generated_plugins.cmake', 'windows/flutter/generated_plugin_registrant.cc',
                   'windows/flutter/generated_plugin_registrant.h', 'windows/flutter/generated_plugins.cmake')
        before = {}
        for relative in self.git('ls-files', '--', *desktop).splitlines():
            file = self.workspace / relative
            app.require(file.is_file() and not file.is_symlink(), '桌面自动注册文件必须是普通文件')
            before[relative] = file.read_bytes()
        try:
            self.execute(task, [Path(self.profile['environment']['FLUTTER_SDK']) / 'bin/flutter',
                                'pub', 'get'], self.workspace)
        finally:
            # Android jobs do not build desktop registrants. Keep generated
            # output for diagnosis, then preserve the selected commit's bytes.
            for relative, original in before.items():
                file = self.workspace / relative
                app.require(file.is_file() and not file.is_symlink(), '依赖解析改变了自动注册文件类型')
                if file.read_bytes() != original:
                    saved = self.root / (task['id'] + '.generated') / relative
                    saved.parent.mkdir(parents=True, exist_ok=True)
                    saved.write_bytes(file.read_bytes())
                    file.write_bytes(original)

    def item(self, collection, identifier):
        return next((item for item in self.state[collection] if item['id'] == identifier), None)

    def submit(self, body):
        action = body.get('action')
        app.require(action in ('build', 'patch', 'publish', 'withdraw', 'refresh'), '未知任务')
        with self.mutex:
            app.require(self.active is None and not self.stopping, '已有任务运行，请等待完成')
            app.require(len(self.state['tasks']) < 1000, '任务历史已达上限，请备份并迁移管理目录')
            data = {'action': action}
            if action in ('build', 'patch'):
                commit = body.get('commit', '')
                app.require(isinstance(commit, str) and SHA.fullmatch(commit), '请选择完整 Git 提交 SHA')
                resolved = app.run(['git', '-C', self.project, 'rev-parse', '--verify', '--end-of-options', commit + '^{commit}'], capture=True).strip()
                app.require(resolved == commit, 'Git 提交不存在')
                data['commit'] = commit
            if action == 'patch':
                base = self.item('baselines', body.get('baseline'))
                app.require(base is not None, '请选择本后台构建的完整基线')
                app.require(base['toolStamp'] == app.tool_stamp(), '工具源码与基线不同，需要恢复工具版本或构建新基线')
                data['baseline'] = base['id']
            if action in ('publish', 'withdraw'):
                patch = self.item('patches', body.get('patch'))
                app.require(patch is not None, '补丁不存在')
                app.require(body.get('confirmed') is True, '必须明确确认发布或撤回')
                app.require(patch['status'] != 'withdrawn', '该补丁已撤回，不允许重新发布')
                if action == 'withdraw':
                    app.require(patch['status'] in ('published', 'publication-unknown'), '补丁尚未发布')
                app.require(not (action == 'publish' and patch.get('withdrawal')), '撤回已开始，不能重新发布')
                data['patch'] = patch['id']
            task = {'id': secrets.token_hex(12), **data, 'status': 'queued', 'createdAt': now()}
            self.state['tasks'].append(task)
            self.active = task['id']
            self.persist()
            self.thread = threading.Thread(target=self.worker, args=(task,), daemon=True)
            self.thread.start()
            return dict(task)

    def worker(self, task):
        try:
            with self.mutex:
                task.update(status='running', startedAt=now())
                self.persist()
            action = task['action']
            if action in ('build', 'patch', 'refresh'):
                self.prepare(task)
            if action in ('build', 'patch'):
                app.require(self.git('status', '--porcelain', '--untracked-files=all') == '',
                            '专用构建副本有未提交修改，拒绝覆盖；请检查后重试')
                self.execute(task, ['git', '-C', self.workspace, 'checkout', '--detach', task['commit']])
                if action == 'patch':
                    self.restore_local_properties(self.item('baselines', task['baseline']))
                self.prepare_dependencies(task)
                if action == 'patch':
                    base = self.item('baselines', task['baseline'])
                    self.restore_ios_inputs(base)
                    app.save(self.workspace_local / 'state.json', {'baseline': base['path'], 'toolStamp': base['toolStamp']})
                # Flutter/CocoaPods may rewrite these tracked inputs even when
                # a native build fails. Preserve evidence, then restore only
                # this job's pre-build bytes in the managed checkout. The
                # release compiler still rejects any source drift itself.
                native_before = {}
                if action == 'build' and self.profile.get('platform') == 'ios':
                    for relative in ('ios/Runner.xcodeproj/project.pbxproj', 'ios/Runner/Info.plist'):
                        file = self.workspace / relative
                        app.require(file.is_file() and not file.is_symlink(), 'iOS 构建输入必须是普通文件')
                        native_before[relative] = file.read_bytes()
                try:
                    self.execute(task, [sys.executable, '-B', ROOT / 'tool/app_cli.py', action], self.workspace)
                finally:
                    for relative, original in native_before.items():
                        file = self.workspace / relative
                        app.require(file.is_file() and not file.is_symlink(), 'iOS 构建改变了输入文件类型')
                        if file.read_bytes() != original:
                            saved = self.root / (task['id'] + '.generated') / relative
                            saved.parent.mkdir(parents=True, exist_ok=True)
                            saved.write_bytes(file.read_bytes())
                            file.write_bytes(original)
                state = app.read(self.workspace_local / 'state.json')
                if action == 'build':
                    path = Path(state['baseline'])
                    receipt = app.archive_receipt(path)
                    result = {'id': task['id'], 'path': str(path), 'toolStamp': state['toolStamp'],
                              'baselineId': receipt['baselineId'], 'release': receipt['release'],
                              'appId': receipt['appId'], 'commit': receipt['gitCommit'],
                              'platform': receipt.get('platform', 'android'),
                              'abi': receipt.get('abi', 'arm64'),
                              **({'ipaSha256': receipt['ipaSha256']} if receipt.get('platform') == 'ios' else {'apkSha256': receipt['apkSha256']}),
                              'origin': app.read(path / 'baseline/project.json')['updateOrigin'],
                              'iosInputs': self.freeze_ios_inputs(path, task),
                              'localProperties': self.freeze_local_properties(path, task)}
                    collection = 'baselines'
                else:
                    candidate = state['patch']
                    manifest = app.read(Path(candidate['path']) / 'manifest.json')['manifest']
                    result = {'id': task['id'], **candidate, 'baselineRef': base['id'], 'commit': task['commit'],
                              'patchId': manifest['patchId'], 'baselineId': manifest['baselineId'],
                              'status': 'ready', 'createdAt': now()}
                    collection = 'patches'
                with self.mutex:
                    self.state[collection].append(result)
                    self.persist()
            if action in ('publish', 'withdraw'):
                self.publication(task)
            with self.mutex:
                task.update(status='succeeded', finishedAt=now())
                self.persist()
        except Exception as error:
            with self.mutex:
                task.update(status='failed', error=str(error), finishedAt=now())
                self.persist()
        finally:
            with self.mutex:
                self.active = None

    def publication(self, task):
        candidate = self.item('patches', task['patch'])
        directory = Path(candidate['path'])
        app.require(app.digest(directory / 'manifest.json') == candidate['manifestSha256'] and
                    app.digest(directory / 'patch.bytecode') == candidate['artifactSha256'], '产物已被修改，拒绝发布')
        frozen = app.read(Path(candidate['baseline']) / 'baseline/project.json')
        origin = frozen['updateOrigin']
        development = app.local_http(origin, frozen.get('allowDevelopmentLan') is True)
        token = os.environ.get('HOTFIX_PUBLISH_TOKEN', '')
        local = self.local / 'publish-token'
        if not token and development and local.is_file():
            token = local.read_text().strip()
        app.require(len(token) >= 24, '服务端缺少发布凭据；本机请先启动 serve，正式环境注入 HOTFIX_PUBLISH_TOKEN')
        if task['action'] == 'withdraw':
            if not candidate.get('withdrawal'):
                output = self.root / ('withdraw-' + task['id'])
                self.execute(task, ['sh', ROOT / 'tool/hotfix', 'policy',
                                    Path(candidate['baseline']) / 'baseline', directory,
                                    self.profile['keys'], output, 'withdraw'])
                with self.mutex:
                    candidate['withdrawal'] = {'path': str(output),
                        'manifestSha256': app.digest(output / 'manifest.json'),
                        'artifactSha256': app.digest(output / 'patch.bytecode')}
                    self.persist()
            control = candidate['withdrawal']
            directory = Path(control['path'])
            app.require(app.digest(directory / 'manifest.json') == control['manifestSha256'] and
                        app.digest(directory / 'patch.bytecode') == control['artifactSha256'], '撤回产物已被修改')
        with self.mutex:
            candidate['status'] = 'publication-unknown'
            self.persist()  # A crash after upload must never imply "not published".
        self.execute(task, ['sh', ROOT / 'tool/hotfix', 'publish', origin,
                            directory / 'manifest.json', directory / 'patch.bytecode'],
                     extra={'HOTFIX_PUBLISH_TOKEN': token, 'HOTFIX_ALLOW_DEV_HTTP': str(development).lower()})
        with self.mutex:
            candidate.update(status='withdrawn' if task['action'] == 'withdraw' else 'published',
                             updatedAt=now())
            self.persist()

    def snapshot(self):
        with self.mutex:
            data = json.loads(json.dumps(self.state))
        for collection in ('baselines', 'patches'):
            for item in data[collection]:
                if collection == 'patches':
                    item['withdrawalStarted'] = bool(item.get('withdrawal'))
                for key in ('path', 'baseline', 'withdrawal', 'localProperties', 'iosInputs'):
                    item.pop(key, None)
        commits = app.run(['git', '-C', self.project, 'log', '--all', '-100', '--format=%H%x09%s'], capture=True)
        data['commits'] = [dict(zip(('sha', 'subject'), line.split('\t', 1))) for line in commits.splitlines()]
        tool_keys = ('FLUTTER_SDK', 'GEN_SNAPSHOT', 'DART_SDK_SOURCE')
        if app.target_platform(self.profile) == 'android':
            tool_keys += ('ANDROID_SDK_ROOT', 'JAVA_HOME')
        data.update(project=self.project.name, platform=app.target_platform(self.profile), workspace=str(self.workspace), active=self.active,
                    prerequisites={key: Path(value).exists() for key, value in self.profile['environment'].items()
                                   if key in tool_keys})
        return data

    def stats(self, baseline):
        base = self.item('baselines', baseline)
        app.require(base is not None, '基线不存在')
        frozen = app.read(Path(base['path']) / 'baseline/project.json')
        origin = frozen['updateOrigin']
        development = app.local_http(origin, frozen.get('allowDevelopmentLan') is True)
        token = os.environ.get('HOTFIX_PUBLISH_TOKEN', '')
        local = self.local / 'publish-token'
        if not token and development and local.is_file():
            token = local.read_text().strip()
        app.require(len(token) >= 24, '缺少发布凭据')
        opener = build_opener(NoRedirect())
        with opener.open(Request(origin.rstrip('/') + '/v1/stats', headers={'Authorization': 'Bearer ' + token}), timeout=15) as response:
            body = response.read(1024 * 1024 + 1)
            app.require(len(body) <= 1024 * 1024, '统计响应过大')
            stats = json.loads(body)
        # Event counts are NOT user counts or a success rate.
        return {'eventCounts': {k: v for k, v in stats['eventCounts'].items() if k.startswith(base['baselineId'] + '/')},
                'uniqueUsers': None}

    def close(self):
        with self.mutex:
            self.stopping = True
            process = self.process
        if process:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
        if self.thread:
            self.thread.join(timeout=10)
            app.require(not self.thread.is_alive(), '任务仍在停止，不能释放管理目录锁')
        self.lock.close()


def handler(console):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(15)

        def log_message(self, *args):
            pass  # No URL/token/credentials in access logs.

        def send(self, status, data, content_type='application/json; charset=utf-8'):
            body = data if isinstance(data, bytes) else json.dumps(data, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('X-Frame-Options', 'DENY')
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'")
            self.end_headers()
            self.wfile.write(body)

        def dispatch(self):
            try:
                expected = f'127.0.0.1:{self.server.server_port}'
                app.require(self.headers.get('Host') == expected, '无效 Host')
                origin = self.headers.get('Origin')
                app.require(origin is None or origin == 'http://' + expected, '跨站请求被拒绝')
                path = urlsplit(self.path)
                if path.path.startswith('/api/'):
                    if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + console.token):
                        self.send(401, {'error': '请输入本机管理令牌'})
                        return
                    if self.command == 'GET' and path.path == '/api/state':
                        self.send(200, console.snapshot())
                        return
                    if self.command == 'GET' and path.path.startswith(('/api/apk/', '/api/package/')):
                        base = console.item('baselines', path.path.rsplit('/', 1)[-1])
                        app.require(base is not None, '基线不存在')
                        ios = base.get('platform') == 'ios'
                        file = Path(base['path']) / ('app.ipa' if ios else 'app.apk')
                        app.require(app.digest(file) == base['ipaSha256' if ios else 'apkSha256'], '归档安装包已被修改')
                        self.send_response(200)
                        self.send_header('Content-Type', 'application/octet-stream' if ios else 'application/vnd.android.package-archive')
                        self.send_header('Content-Length', str(file.stat().st_size))
                        self.send_header('Cache-Control', 'no-store')
                        self.send_header('X-Content-Type-Options', 'nosniff')
                        self.end_headers()
                        with file.open('rb') as stream:
                            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                                self.wfile.write(chunk)
                        return
                    if self.command == 'GET' and path.path.startswith('/api/log/'):
                        identifier = path.path.removeprefix('/api/log/')
                        app.require(ID.fullmatch(identifier) and console.item('tasks', identifier), '任务不存在')
                        file = console.root / (identifier + '.log')
                        text = file.read_bytes()[-256 * 1024:].decode(errors='replace') if file.exists() else ''
                        self.send(200, {'text': text})
                        return
                    if self.command == 'GET' and path.path.startswith('/api/stats/'):
                        self.send(200, console.stats(path.path.removeprefix('/api/stats/')))
                        return
                    if self.command == 'POST' and path.path == '/api/tasks':
                        app.require(self.headers.get('Content-Type') == 'application/json', '需要 JSON 请求')
                        length = int(self.headers.get('Content-Length', '0'))
                        app.require(0 < length <= 4096 and not self.headers.get('Transfer-Encoding'), '请求大小无效')
                        body = json.loads(self.rfile.read(length))
                        app.require(isinstance(body, dict), '需要 JSON 对象')
                        self.send(202, console.submit(body))
                        return
                    self.send(404, {'error': '接口不存在'})
                    return
                if self.command != 'GET':
                    self.send(405, {'error': '不支持的方法'})
                    return
                static = Path(__file__).parent / 'static'
                name = 'index.html' if path.path == '/' else path.path.lstrip('/')
                file = (static / name).resolve()
                app.require(file.is_relative_to(static.resolve()) and file.is_file(), '页面不存在')
                types = {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8'}
                self.send(200, file.read_bytes(), types.get(file.suffix, 'application/octet-stream'))
            except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
                self.send(400, {'error': str(error)})
            except Exception:
                self.send(500, {'error': '内部错误，请检查服务端配置'})

        def do_GET(self):
            self.dispatch()

        def do_POST(self):
            self.dispatch()
    return Handler


def main():
    parser = argparse.ArgumentParser(description='本机 Android/iOS 热更新后台，无 Jenkins 依赖')
    parser.add_argument('--project', type=Path, default=Path.cwd())
    parser.add_argument('--platform', choices=['android', 'ios'])
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--with-delivery', action='store_true', help='同时启动配置中显式允许的开发 HTTP 分发服务')
    args = parser.parse_args()
    os.umask(0o077)
    app.require(1 <= args.port <= 65535, '端口无效')
    console = Console(args.project.resolve(), args.platform)
    delivery = None
    try:
        if args.with_delivery:
            config = app.read(console.project / ('hotfix.' + app.target_platform(console.profile) + '.json'))
            origin = config['updateOrigin']
            app.require(app.local_http(origin, config.get('allowDevelopmentLan') is True),
                        '--with-delivery 只适用于显式开发 HTTP 测试地址')
            host = urlsplit(origin).hostname
            port = urlsplit(origin).port or 80
            app.require(port != args.port, '管理与分发服务不能使用相同端口')
            with socket.socket() as probe:
                probe.bind((host, port))
            delivery_env = {**os.environ, **console.profile['environment']}
            if console.platform_scope:
                delivery_env['HOTFIX_ACTIVE_PLATFORM'] = console.platform_scope
            delivery = subprocess.Popen([sys.executable, '-B', str(ROOT / 'tool/app_cli.py'), 'serve'],
                cwd=console.project, env=delivery_env,
                stdin=subprocess.DEVNULL, start_new_session=True)
            ready = False
            for _ in range(100):
                app.require(delivery.poll() is None, '分发服务启动失败')
                with socket.socket() as probe:
                    if probe.connect_ex((host, port)) == 0:
                        ready = True
                        break
                time.sleep(.1)
            app.require(ready, '分发服务未就绪')
        server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(console))
        server.timeout = 1
        print(f'后台: http://127.0.0.1:{args.port}\n管理令牌文件: {console.token_file}\n专用构建副本: {console.workspace}\n仅本机使用；Ctrl+C 停止，不自动发布或操作设备。', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()
    finally:
        console.close()
        if delivery:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(delivery.pid, signal.SIGTERM)
            try:
                delivery.wait(timeout=5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(delivery.pid, signal.SIGKILL)
                delivery.wait()


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        sys.exit('ERROR: ' + str(error))
