"""Regression checks for local build isolation and owned-resource lifecycle."""
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


api = module('local_container')
pg = module('local_postgres')


class LocalEnvironmentTests(unittest.TestCase):
    def fixture(self, root):
        for name in ('Containerfile.local', 'Package.swift', 'Package.resolved'):
            (root / name).write_text('synthetic fixture')
        for name in ('Sources', 'Tests'):
            (root / name).mkdir()
            (root / name / 'Fixture.swift').write_text('// synthetic fixture')
        (root / '.env').write_text('synthetic noncredential fixture')
        (root / '.git').mkdir()

    def test_build_context_excludes_environment_and_repository_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'source'; root.mkdir()
            out = Path(tmp) / 'context'; out.mkdir()
            self.fixture(root)
            api.stage_context(out, root)
            self.assertEqual({p.name for p in out.iterdir()}, {'Containerfile.local', 'Package.swift', 'Package.resolved', 'Sources', 'Tests'})
            self.assertFalse((out / '.env').exists())
            self.assertFalse((out / '.git').exists())

    def test_sensitive_named_or_symlinked_sources_fail_before_copy(self):
        for mode in ('key', 'symlink'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'source'; root.mkdir()
                out = Path(tmp) / 'context'; out.mkdir()
                self.fixture(root)
                if mode == 'key':
                    (root / 'Sources' / 'fixture.key').touch()
                else:
                    (root / 'Sources' / 'link').symlink_to(root / '.env')
                with self.assertRaises(ValueError):
                    api.stage_context(out, root)
                self.assertEqual(list(out.iterdir()), [])

    def test_start_is_loopback_nonroot_and_does_not_forward_secrets(self):
        args = api.start_command(18080)
        self.assertIn('127.0.0.1:18080:8080', args)
        self.assertIn('10001:10001', args)
        self.assertIn('--read-only', args)
        self.assertNotIn('--env-file', args)
        self.assertNotIn('--ssh', args)

    def test_foreign_api_container_is_rejected(self):
        result = subprocess.CompletedProcess([], 0, json.dumps([{'configuration': {'id': api.NAME, 'labels': {api.LABEL: 'other'}}}]), '')
        with patch.object(api.subprocess, 'run', return_value=result), self.assertRaises(RuntimeError):
            api.inspect_owned()

    def run_pg_start(self, state, owner=None):
        volume = {'configuration': {'name': pg.VOLUME, 'labels': {pg.LABEL: owner or pg.OWNER}}}
        replies = [subprocess.CompletedProcess([], 0, json.dumps([volume]), ''), subprocess.CompletedProcess([], 0, '[]', '')]
        with patch.object(pg, 'verify_directory'), patch.object(pg, 'verify_file'), patch.object(pg.subprocess, 'run', side_effect=replies), patch.object(pg, 'owned', return_value={'status': {'state': state}}), patch.object(pg, 'command') as cmd:
            pg.start()
            return cmd.call_args_list

    def test_owned_running_database_is_not_replaced(self):
        self.assertEqual(self.run_pg_start('running'), [])

    def test_stopped_database_restarts_without_recreating_volume_or_secrets(self):
        calls = self.run_pg_start('stopped')
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].args[0], ['container', 'start', pg.NAME])

    def test_foreign_volume_is_rejected(self):
        with self.assertRaises(RuntimeError):
            self.run_pg_start('stopped', owner='other')

    def test_existing_privileged_role_is_rejected_without_password_reset(self):
        with patch.object(pg, 'verify_directory'), patch.object(pg, 'verify_file', return_value='x' * 48), patch.object(pg, 'query', side_effect=['1\n', '0\n']) as query, self.assertRaises(RuntimeError):
            pg.configure_role()
        self.assertEqual(query.call_count, 2)
        self.assertTrue(all('CREATE ROLE' not in call.args[0] for call in query.call_args_list))

    def test_secret_generation_requires_git_exclusion_first(self):
        result = subprocess.CompletedProcess([], 1, '', '')
        with patch.object(pg.subprocess, 'run', return_value=result), patch.object(pg, 'command', return_value=''), patch.object(pg, 'verify_directory') as directory, patch.object(pg.secrets, 'token_urlsafe') as generate, self.assertRaises(RuntimeError):
            pg.setup()
        directory.assert_not_called()
        generate.assert_not_called()


if __name__ == '__main__':
    unittest.main()
