import json
import os
import subprocess
import sys

import yaml
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import migration_ci as ci


class IsolatedMigrationSafetyTests(unittest.TestCase):
    def fixture(self, root):
        for name, content in {
            'db/schema.sql': 'CREATE TABLE fixture(id int);',
            'db/migrations/atlas.sum': 'h1:synthetic',
            'db/migrations/20261101000000_fixture.sql': 'CREATE TABLE fixture(id int);',
            'db/tests/001_fixture.sql': 'BEGIN; ROLLBACK;',
            'scripts/migration_replay.sh': '#!/bin/bash\nexit 0\n',
        }.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)

    def test_invalid_or_zero_base_is_rejected_before_git(self):
        with patch.object(ci, 'command') as command:
            for value in ['HEAD', 'main', '0' * 40, 'a' * 39, 'A' * 40, 'a' * 40 + ';exit 0']:
                with self.subTest(value=value), self.assertRaises(RuntimeError):
                    ci.trusted_base(value)
            command.assert_not_called()

    def test_base_must_be_ancestor_and_contain_migration_history(self):
        value = 'a' * 40
        with patch.object(ci, 'command', side_effect=['', RuntimeError('not ancestor')]):
            with self.assertRaisesRegex(RuntimeError, 'not ancestor'):
                ci.trusted_base(value)
        with patch.object(ci, 'command', side_effect=['', '', 'db/migrations/atlas.sum\n']):
            with self.assertRaisesRegex(RuntimeError, 'no historical'):
                ci.trusted_base(value)

    def test_atlas_sum_symlink_is_rejected_before_any_atlas_execution_or_write(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            sentinel = root / 'outside-sentinel'
            sentinel.write_bytes(b'KEEP THIS EXACT VALUE')
            checksum = root / 'db/migrations/atlas.sum'
            checksum.unlink()
            checksum.symlink_to(sentinel)
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'command', return_value=''), patch.object(ci, 'download_atlas') as download, patch.object(ci, 'verify_guard') as guard, patch('sys.argv', ['migration_ci.py', '--base', 'a' * 40]):
                with self.assertRaisesRegex(RuntimeError, 'symlink'):
                    ci.main()
                download.assert_not_called()
                guard.assert_not_called()
            self.assertEqual(sentinel.read_bytes(), b'KEEP THIS EXACT VALUE')

    def test_symlinked_sql_parent_and_untracked_inputs_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            real = root / 'real-tests'
            (root / 'db/tests').rename(real)
            (root / 'db/tests').symlink_to(real, target_is_directory=True)
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'command', return_value=''):
                with self.assertRaisesRegex(RuntimeError, 'symlink'):
                    ci.validated_inputs()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'command', side_effect=RuntimeError('untracked')):
                with self.assertRaisesRegex(RuntimeError, 'untracked'):
                    ci.validated_inputs()

    def test_snapshot_excludes_git_local_secrets_and_unrelated_entries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            for name in ['.git/config', '.local/secrets/never-read', 'db/migrations/unrelated.txt']:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('NOT AN INPUT')
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'command', return_value=''):
                snapshot = ci.validated_inputs()
            self.assertEqual(len(snapshot), 5)
            staged = root / 'stage'
            ci.stage_inputs(staged, snapshot)
            self.assertEqual(sorted(str(p.relative_to(staged)) for p in staged.rglob('*') if p.is_file()), [
                'db/migrations/20261101000000_fixture.sql', 'db/migrations/atlas.sum', 'db/schema.sql', 'db/tests/001_fixture.sql', 'replay.sh'])
            # Later source edits cannot change already validated snapshot bytes.
            (root / 'db/schema.sql').write_text('CHANGED AFTER SNAPSHOT')
            self.assertEqual((staged / 'db/schema.sql').read_text(), 'CREATE TABLE fixture(id int);')

    def test_job_workspace_trust_is_exact_process_scoped_and_inherited_by_guard_children(self):
        workflow = yaml.safe_load((ci.ROOT / '.github/workflows/ci.yml').read_text())
        steps = workflow['jobs']['migrations']['steps']
        configured = [step for step in steps if 'GIT_CONFIG_COUNT' in step.get('env', {})]
        self.assertEqual(len(configured), 1)
        policy = configured[0]['env']
        self.assertEqual(policy['GIT_CONFIG_COUNT'], '1')
        self.assertEqual(policy['GIT_CONFIG_KEY_0'], 'safe.directory')
        self.assertEqual(policy['GIT_CONFIG_VALUE_0'], '${{ github.workspace }}')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            home = root / 'home'
            home.mkdir()
            config = home / '.gitconfig'
            original_config = b'[user]\n    name = Synthetic Git Test\n'
            config.write_bytes(original_config)
            environment = {'PATH': os.environ['PATH'], 'HOME': str(home),
                           'XDG_CONFIG_HOME': str(home / '.config'), 'GIT_CONFIG_NOSYSTEM': '1'}
            repositories = [root / 'workspace', root / 'unrelated']
            for repository in repositories:
                subprocess.run(['git', 'init', '--quiet', str(repository)], env=environment, check=True, capture_output=True)
            local_config = (repositories[0] / '.git/config').read_bytes()
            # This upstream Git test fixture exercises the real ownership check
            # without changing host file ownership or needing a privileged user.
            environment['GIT_TEST_ASSUME_DIFFERENT_OWNER'] = '1'
            def inspect(repository, env):
                return subprocess.run(['git', '-C', str(repository), 'rev-parse', '--show-toplevel'], env=env, capture_output=True, text=True)
            self.assertEqual(inspect(repositories[0], environment).returncode, 128)
            scoped = dict(environment, GIT_CONFIG_COUNT=policy['GIT_CONFIG_COUNT'],
                          GIT_CONFIG_KEY_0=policy['GIT_CONFIG_KEY_0'], GIT_CONFIG_VALUE_0=str(repositories[0]))
            allowed = inspect(repositories[0], scoped)
            self.assertEqual(allowed.returncode, 0)
            self.assertEqual(allowed.stdout.strip(), str(repositories[0]))
            scopes = subprocess.run(['git', 'config', '--show-scope', '--get-all', 'safe.directory'], env=scoped, capture_output=True, text=True, check=True)
            self.assertEqual(scopes.stdout.strip(), 'command\t' + str(repositories[0]))
            child = subprocess.run([sys.executable, '-I', '-c',
                'import subprocess,sys; subprocess.run(["git","-C",sys.argv[1],"rev-parse","--show-toplevel"],check=True)', str(repositories[0])],
                env=scoped, capture_output=True, text=True)
            self.assertEqual(child.returncode, 0)
            self.assertEqual(inspect(repositories[1], scoped).returncode, 128)
            self.assertEqual(inspect(repositories[0], environment).returncode, 128)
            self.assertEqual(config.read_bytes(), original_config)
            self.assertEqual((repositories[0] / '.git/config').read_bytes(), local_config)

    def test_cleanup_refuses_foreign_label_and_never_deletes_other_containers(self):
        owner = 'owner'
        name = 'sauna-migration-ci-' + owner
        candidate = {'configuration': {'id': name, 'labels': {ci.LABEL: 'someone-else'}}}
        with patch.object(ci, 'command', side_effect=[name + '\n', json.dumps([candidate])]) as command:
            with self.assertRaisesRegex(RuntimeError, 'foreign'):
                ci.cleanup_apple(name, owner)
            self.assertEqual(command.call_count, 2)
        with patch.object(ci, 'command', return_value='sauna-postgres-local\n') as command:
            ci.cleanup_apple(name, owner)
            self.assertEqual(command.call_count, 1)

    def test_cleanup_deletes_only_exact_owned_resource_after_readback(self):
        owner = 'owner'
        name = 'sauna-migration-ci-' + owner
        candidate = {'configuration': {'id': name, 'labels': {ci.LABEL: owner}}}
        with patch.object(ci, 'command', side_effect=[name + '\n', json.dumps([candidate]), '']) as command:
            ci.cleanup_apple(name, owner)
            self.assertEqual(command.call_args.args[0], ['container', 'delete', '--force', name])


if __name__ == '__main__':
    unittest.main()
