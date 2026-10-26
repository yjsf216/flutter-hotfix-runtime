import argparse
from contextlib import ExitStack
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import jenkins_entry as runner


class RunnerCheck(unittest.TestCase):
    def test_readable_labels_remain_safe_git_refs(self):
        tag=runner.baseline_tag('ios','3.12.4+1082','fix(ui): 修复设置页 / 名称: 问题?[test]','a'*64)
        self.assertIn('修复设置页',tag)
        self.assertTrue(tag.endswith('a'*12))
        subprocess.run(['git','check-ref-format','refs/tags/'+tag],check=True)
        self.assertLess(len(runner.baseline_tag('android','1.0.0+1','很长的说明'*100,'a'*64)),70)

    def test_short_labels_resolve_uniquely_and_keep_platform_checks(self):
        identity='a'*64;rows={identity:{'platform':'ios'}}
        tag=runner.baseline_tag('ios','1.0.0+1','修复名称',identity)
        self.assertEqual(runner.resolve_baseline(tag,rows,'ios'),identity)
        self.assertEqual(runner.resolve_baseline('hotfix-base-ios-'+identity,rows,'ios'),identity)
        with self.assertRaises(ValueError):runner.resolve_baseline(tag,rows,'android')
        rows['a'*12+'b'*52]={'platform':'ios'}
        with self.assertRaises(ValueError):runner.resolve_baseline(tag,rows,'ios')

    def test_low_disk_stops_before_allocating_a_new_checkout(self):
        catalogue=unittest.mock.Mock();catalogue.root=Path('/unused')
        with patch.object(runner.shutil,'disk_usage',return_value=argparse.Namespace(free=0)):
            with self.assertRaisesRegex(ValueError,'8 GiB'):
                runner.baseline(argparse.Namespace(resume_directory=None),{},catalogue,Path('/unused'),'a'*40)
        catalogue.allocate.assert_not_called()

    def test_patch_routes_to_baseline_pinned_tool_release(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);cat=runner.Catalogue(root/'data');directory=cat.allocate()
            pinned=root/'old-tools/ci/jenkins_entry.py';pinned.parent.mkdir(parents=True);pinned.write_text('# fixture')
            identity='b'*64
            runner.save(cat.index,{identity:{'archive':str(directory/'archive'),'platform':'android'}})
            runner.save(directory/'ci-build.json',{'toolsRoot':str(pinned.parent.parent)})
            token=root/'token';token.write_text('x'*24)
            config=root/'config.json';runner.save(config,{'environment':{},'dataRoot':str(cat.root),
                'origin':'https://updates.example.com','uploadTokenFile':str(token)})
            argv=['runner','--config',str(config),'--mode','patch','--platform','android',
                  '--source',str(root),'--commit','a'*40,'--branch','test','--baseline-id',identity,
                  '--result',str(root/'result.json')]
            with patch.object(runner.sys,'argv',argv),patch.object(runner,'commit',return_value='a'*40), \
                 patch.object(runner,'run') as execute,patch.dict(runner.os.environ):
                runner.main()
            self.assertIn(str(pinned),execute.call_args.args[0])

    def test_completed_archive_retry_uploads_without_recompiling(self):
        with tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
            root=Path(temp);project=root/'project';archive=root/'archive'
            origin='https://updates.example.com';sha='a'*40
            runner.save(project/'hotfix.android.json',{'updateOrigin':origin,'patchNumberingOrigin':origin})
            runner.save(root/'ci-build.json',{'toolStamp':'same','sourceCommit':sha})
            runner.save(archive/'android-release.json',{'gitCommit':sha,'publicKeySha256':'key',
                'baselineId':'b'*64,'release':'1.0.0+1'})
            runner.save(archive/'baseline/project.json',{'dartDefines':{'APP_CHANNEL':'test'}})
            catalogue=unittest.mock.Mock();catalogue.owned.return_value=root
            args=argparse.Namespace(resume_directory=root,platform='android',branch='test')
            config={'environment':{'FLUTTER_SDK':'/unused'},'dataRoot':str(root),
                    'origin':origin,'keys':str(root/'keys')}
            for name,value in {'head':sha,'run':'','source_directory':None,'environment':{},
                               'app_info':{'version':'1.0.0+1'},'tool_stamp':'same','digest':'key'}.items():
                stack.enter_context(patch.object(runner,name,return_value=value))
            compile_call=stack.enter_context(patch.object(runner,'cli',side_effect=AssertionError('recompiled')))
            upload=stack.enter_context(patch.object(runner.upload_baseline,'upload'))
            stack.enter_context(patch.object(runner,'Client'))
            result=runner.baseline(args,config,catalogue,project,sha)
            compile_call.assert_not_called();upload.assert_called_once()
            self.assertEqual(result['baselineId'],'b'*64)

    def test_cache_cleanup_keeps_archive_and_refuses_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);project=root/'project';project.mkdir()
            subprocess.run(['git','init','-q',str(project)],check=True)
            archive=root/'archive';archive.mkdir();(archive/'app.apk').write_bytes(b'keep')
            (project/'build').mkdir();(project/'build/output').write_bytes(b'cache')
            runner.trim_build_cache(project)
            self.assertEqual((archive/'app.apk').read_bytes(),b'keep')
            (project/'build').symlink_to(archive,target_is_directory=True)
            with self.assertRaises(ValueError):runner.trim_build_cache(project)
            self.assertTrue((archive/'app.apk').exists())

    def test_shared_objects_with_isolated_worktrees(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); source = root/'source'; source.mkdir()
            def git(*args): return subprocess.check_output(['git','-C',str(source),*args],text=True).strip()
            git('init','-q');git('config','user.name','Fixture');git('config','user.email','fixture@example.invalid')
            (source/'example').write_text('base')
            git('add','.');git('commit','-qm','base');git('remote','add','origin','git@example.invalid:fixture/app.git')
            first = git('rev-parse','HEAD')
            a=root/'a/project';b=root/'b/project';cache=root/'cache'
            runner.source_directory(source,a,first,cache)
            (source/'example').write_text('fix');git('commit','-qam','fix');second=git('rev-parse','HEAD')
            runner.source_directory(source,b,second,cache)
            def common(p): return subprocess.check_output(['git','-C',str(p),'rev-parse','--git-common-dir'],text=True).strip()
            self.assertEqual(common(a),common(b))
            self.assertEqual((a/'example').read_text(),'base')
            self.assertEqual((b/'example').read_text(),'fix')
            self.assertEqual(git('rev-parse','HEAD'),second)
            (a/'example').write_text('pending')
            with self.assertRaises(ValueError): runner.source_directory(source,a,second,cache)
            self.assertEqual((a/'example').read_text(),'pending')

    def test_commit_input_never_becomes_a_git_option(self):
        with patch.object(runner, 'run', side_effect=AssertionError('spawned')):
            for value in ['--help', 'origin/develop', 'a'*40+';echo bad']:
                with self.assertRaises(ValueError): runner.commit(Path('/unused'), value)

    def test_owned_clone_does_not_change_source_and_refuses_dirty_reuse(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); source = root/'source'; source.mkdir()
            def git(*args): return subprocess.check_output(['git','-C',str(source),*args],text=True).strip()
            git('init','-q'); git('config','user.name','Fixture');git('config','user.email','fixture@example.invalid')
            (source/'example').write_text('source')
            git('add','example');git('commit','-qm','fixture');git('remote','add','origin','git@example.invalid:fixture/app.git')
            sha=git('rev-parse','HEAD'); target=root/'build/project'
            runner.source_directory(source,target,sha)
            self.assertEqual(git('status','--porcelain'),'')
            (target/'example').write_text('pending')
            with self.assertRaises(ValueError): runner.source_directory(source,target,sha)
            self.assertEqual((target/'example').read_text(),'pending')

    def test_tool_mismatch_stops_before_checkout_sign_or_upload(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);archive=root/'archive';archive.mkdir()
            runner.save(archive/'android-release.json',{'baselineId':'a'*64})
            runner.save(root/'ci-build.json',{'toolStamp':'old'})
            catalogue=unittest.mock.Mock();catalogue.owned.return_value=root
            args=argparse.Namespace(platform='android',baseline_id='a'*64)
            with patch.dict(runner.os.environ,{'HOTFIX_BASELINE_ARCHIVE':str(archive)}), \
                 patch.object(runner,'tool_stamp',return_value='new'), \
                 patch.object(runner,'source_directory',side_effect=AssertionError('checkout')):
                with self.assertRaisesRegex(ValueError,'baseline-matched'):runner.patch_inner(args,{},catalogue,root,'b'*40)


if __name__=='__main__':unittest.main()
