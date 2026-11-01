import json
import unittest
from unittest.mock import patch

import local_integration_db as integration
import postgresql_prerequisites as prerequisites


class PostgreSQLPrerequisiteSafetyTests(unittest.TestCase):
    def test_only_reviewed_manifest_is_accepted(self):
        prerequisites.validate_manifest(json.dumps(prerequisites.EXPECTED).encode())
        for invalid in [None,b'',b'[]',b'{}',b'{"extension":"btree_gist","extension":"btree_gist","version":"1.8","schema":"extensions","owner":"postgres"}',
                        json.dumps({**prerequisites.EXPECTED,'sql':'DROP DATABASE other'}).encode(),
                        json.dumps({**prerequisites.EXPECTED,'version':'1.7'}).encode(),
                        json.dumps({**prerequisites.EXPECTED,'schema':'public'}).encode(),
                        json.dumps({**prerequisites.EXPECTED,'owner':'sauna_app'}).encode()]:
            with self.subTest(invalid=invalid), self.assertRaises(RuntimeError):
                prerequisites.validate_manifest(invalid)

    def test_unreviewed_prerequisite_fails_before_password_access_or_staging(self):
        snapshot = {'db/schema.sql':b'CREATE TABLE sample(id int);',
                    'db/postgresql-prerequisites.json':json.dumps({**prerequisites.EXPECTED,'version':'1.7'}).encode()}
        with patch.object(integration.platform,'system',return_value='Darwin'), \
             patch.object(integration,'ensure_port_free'), \
             patch.object(integration.migration_ci,'validated_inputs',return_value=snapshot), \
             patch.object(integration,'approved_password') as credential, \
             patch.object(integration,'stage_password') as stage:
            with self.assertRaises(RuntimeError): integration.run_tests()
            credential.assert_not_called()
            stage.assert_not_called()

    def test_manifest_never_generates_superuser_sql(self):
        before=prerequisites.BOOTSTRAP_SQL
        prerequisites.validate_manifest(json.dumps(dict(reversed(list(prerequisites.EXPECTED.items())))).encode())
        self.assertEqual(prerequisites.BOOTSTRAP_SQL,before)
        self.assertNotIn('IF NOT EXISTS',before)
        self.assertNotIn('SUPERUSER',before)
        self.assertIn("CREATE EXTENSION btree_gist WITH SCHEMA extensions VERSION '1.8'",before)
