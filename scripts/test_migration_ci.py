import json
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
