from pathlib import Path
import unittest
import yaml


class AuthenticationContractTests(unittest.TestCase):
    def test_csrf_is_required_only_after_session_issuance(self):
        document = yaml.safe_load((Path(__file__).parents[1] / 'Sources/SaunaAPIContract/openapi.yaml').read_text())
        for path, methods in document['paths'].items():
            if not path.startswith('/auth/'):
                continue
            for method in methods.values():
                csrf = next(p for p in method['parameters'] if p['name'] == 'X-Sauna-CSRF')
                self.assertEqual(csrf['required'], path in {'/auth/logout', '/auth/sessions/revoke-all'}, path)
                origin = next(p for p in method['parameters'] if p['name'] == 'Origin')
                self.assertTrue(origin['required'])
        for path in ['/auth/session', '/auth/logout', '/auth/sessions/revoke-all']:
            operation = next(iter(document['paths'][path].values()))
            self.assertEqual(operation['security'], [{'CustomerSession': []}, {'StaffSession': []}])

    def test_problem_titles_and_session_secrets_are_bounded(self):
        document = yaml.safe_load((Path(__file__).parents[1] / 'Sources/SaunaAPIContract/openapi.yaml').read_text())
        schemas = document['components']['schemas']
        self.assertEqual(set(schemas['AuthenticationProblem']['properties']['title']['enum']), {'Bad Request', 'Unauthorized', 'Forbidden', 'Payload Too Large', 'Too Many Requests', 'Service Unavailable'})
        self.assertNotIn('token', schemas['AuthSession']['properties'])
        self.assertEqual(schemas['PasskeyFinishRequest']['properties']['credentialJSON']['maxLength'], 65536)
