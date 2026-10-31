"""Public-wire contract checks, including rejection of sensitive or malformed payloads."""

import unittest
from copy import deepcopy

from jsonschema import Draft202012Validator, ValidationError

from validate_openapi import load_contract, response_schema, validate_contract


class PublicContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = load_contract()

    def validator(self, path, status="200", media_type="application/json"):
        return Draft202012Validator(response_schema(self.document, path, status, media_type))

    def test_openapi_and_all_success_and_error_examples_are_valid(self):
        self.assertEqual(validate_contract(self.document), 4)

    def test_public_endpoints_require_no_authentication(self):
        self.assertEqual(set(self.document["paths"]), {"/health", "/version"})
        self.assertEqual(self.document["security"], [])
        for path in self.document["paths"].values():
            self.assertEqual(path["get"]["security"], [])

    def test_external_references_are_rejected_before_validation(self):
        document = deepcopy(self.document)
        document["components"]["schemas"]["External"] = {"$ref": "https://example.invalid/schema"}
        with self.assertRaisesRegex(ValueError, "Remote references are not allowed"):
            validate_contract(document)

    def test_health_rejects_non_success_missing_status_and_internal_details(self):
        validator = self.validator("/health")
        for payload in [{}, {"status": "failed"}, {"status": "ok", "database": "connected"}]:
            with self.subTest(payload=payload), self.assertRaises(ValidationError):
                validator.validate(payload)

    def test_version_requires_public_release_versions_without_build_metadata(self):
        validator = self.validator("/version")
        for payload in [
            {"version": "0.1.0"},
            {"apiVersion": "1.0.0", "version": "0.1.0+git.abc"},
            {"apiVersion": "1.0.0", "version": "0.1.0", "hostname": "internal"},
            {"apiVersion": "1.0.0", "version": 1},
        ]:
            with self.subTest(payload=payload), self.assertRaises(ValidationError):
                validator.validate(payload)

    def test_error_is_fixed_problem_and_rejects_exception_details(self):
        public = {"type": "about:blank", "title": "Service Unavailable", "status": 503}
        for path in ["/health", "/version"]:
            validator = self.validator(path, "503", "application/problem+json")
            validator.validate(public)
            for payload in [
                {**public, "detail": "database connection failed"},
                {**public, "title": "internal exception"},
                {**public, "status": 500},
                {"title": "Service Unavailable", "status": 503},
            ]:
                with self.subTest(path=path, payload=payload), self.assertRaises(ValidationError):
                    validator.validate(payload)

    def test_version_rejects_trailing_line_terminators_for_both_fields(self):
        validator = self.validator("/version")
        for field in ["apiVersion", "version"]:
            for suffix in ["\n", "\r\n", "\r", "\u2028", "\u2029"]:
                payload = {"apiVersion": "1.0.0", "version": "0.1.0"}
                payload[field] += suffix
                with self.subTest(field=field, suffix=repr(suffix)), self.assertRaises(ValidationError):
                    validator.validate(payload)


if __name__ == "__main__":
    unittest.main()
