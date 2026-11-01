import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

import local_integration_db as integration


class IntegrationDatabaseSafetyTests(unittest.TestCase):
    def test_psql_metacommands_and_executable_schema_fail_before_credential_access(self):
        for content in [b'\\! touch /tmp/synthetic-marker', b'\\copy public.users TO PROGRAM \'true\'',
                        b'CREATE FUNCTION danger() RETURNS void LANGUAGE plpgsql AS $$ BEGIN END $$;',
                        b'DO $$ BEGIN END $$;', b'ALTER TABLE public.users DROP COLUMN id;', b'']:
            with self.subTest(content=content), \
                 patch.object(integration.platform, 'system', return_value='Darwin'), \
                 patch.object(integration, 'ensure_port_free'), \
                 patch.object(integration.migration_ci, 'validated_inputs', return_value={'db/schema.sql': content}), \
                 patch.object(integration, 'approved_password') as credential, \
                 patch.object(integration, 'stage_password') as stage:
                with self.assertRaises(RuntimeError):
                    integration.run_tests()
                credential.assert_not_called()
                stage.assert_not_called()

    def test_valid_schema_ddl_is_accepted(self):
        integration.validate_schema(b'CREATE TABLE sample(id uuid PRIMARY KEY); CREATE INDEX sample_id ON sample(id); ALTER TABLE sample ADD CONSTRAINT sample_check CHECK(id IS NOT NULL);')

    def test_occupied_port_never_reads_credentials_or_starts_a_vm(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            with patch.object(integration, 'PORT', listener.getsockname()[1]), \
                 patch.object(integration.platform, 'system', return_value='Darwin'), \
                 patch.object(integration, 'approved_password') as credential, \
                 patch.object(integration, 'command') as command:
                with self.assertRaisesRegex(RuntimeError, 'occupied'):
                    integration.run_tests()
                credential.assert_not_called()
                command.assert_not_called()

    def test_approved_file_and_parent_permissions_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            (repository / '.git').mkdir()
            private = repository / '.local'
            private.mkdir(mode=0o700)
            secrets = private / 'secrets'
            secrets.mkdir(mode=0o700)
            value = secrets / 'postgres-app-password'
            value.write_text('A' * 48 + '\n')
            value.chmod(0o600)
            with patch.object(integration, 'command', return_value=str(repository / '.git')):
                self.assertEqual(integration.approved_password(), value.resolve())
                value.chmod(0o644)
                with self.assertRaises(RuntimeError):
                    integration.approved_password()
                value.chmod(0o600)
                secrets.chmod(0o755)
                with self.assertRaises(RuntimeError):
                    integration.approved_password()

    def test_symlinked_secret_never_enters_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / 'target'
            target.write_text('A' * 48)
            target.chmod(0o600)
            link = root / 'link'
            link.symlink_to(target)
            destination = root / 'copy'
            with self.assertRaises(OSError):
                integration.stage_password(link, destination)
            self.assertFalse(destination.exists())
            self.assertEqual(target.read_text(), 'A' * 48)

    def test_staged_copy_is_private_and_original_is_not_changed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.write_bytes(b'A' * 48 + b'\n')
            source.chmod(0o600)
            destination = root / 'copy'
            integration.stage_password(source, destination)
            self.assertEqual(destination.read_bytes(), source.read_bytes())
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            destination.unlink()
            self.assertEqual(source.read_bytes(), b'A' * 48 + b'\n')

    def test_cleanup_never_deletes_an_unrelated_vm(self):
        name = 'sauna-integration-db-test'
        response = [{'configuration': {'id': name, 'labels': {integration.LABEL: 'other-owner'}}}]
        with patch.object(integration, 'command', side_effect=[name + '\n', json.dumps(response)]) as command:
            with self.assertRaisesRegex(RuntimeError, 'foreign'):
                integration.cleanup(name, 'owned')
            self.assertEqual(command.call_count, 2)
            self.assertTrue(all('delete' not in call.args[0] for call in command.call_args_list))

    def test_missing_vm_cleanup_does_not_inspect_other_metadata(self):
        with patch.object(integration, 'command', return_value='another-vm\n') as command:
            integration.cleanup('sauna-integration-db-owned', 'owned')
            self.assertEqual(command.call_count, 1)
