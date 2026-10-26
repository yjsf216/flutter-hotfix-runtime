import argparse
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import jenkins_entry as runner


class RunnerCheck(unittest.TestCase):
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
