#!/usr/bin/env python3
"""Validate the OpenAPI contract and every declared success/error example offline."""

from pathlib import Path

import yaml
from jsonschema import Draft202012Validator
from openapi_spec_validator import validate

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "Sources/SaunaAPIContract/openapi.yaml"


def load_contract():
    return yaml.safe_load(CONTRACT.read_text())


def resolve(document, value):
    """Resolve only local JSON pointers; remote references are not allowed."""
    seen = set()
    while "$ref" in value:
        ref = value["$ref"]
        if not ref.startswith("#/") or ref in seen:
            raise ValueError(f"Unsupported or cyclic reference: {ref}")
        seen.add(ref)
        value = document
        for part in ref[2:].split("/"):
            value = value[part.replace("~1", "/").replace("~0", "~")]
    return value


def response_schema(document, path, status, media_type):
    response = resolve(document, document["paths"][path]["get"]["responses"][status])
    return resolve(document, response["content"][media_type]["schema"])


def validate_contract(document):
    def check_references(value):
        if isinstance(value, dict):
            if "$ref" in value and not value["$ref"].startswith("#/"):
                raise ValueError("Remote references are not allowed")
            for child in value.values():
                check_references(child)
        elif isinstance(value, list):
            for child in value:
                check_references(child)

    check_references(document)
    validate(document)
    count = 0
    for path in document["paths"].values():
        for operation in path.values():
            for response in operation["responses"].values():
                response = resolve(document, response)
                for media in response.get("content", {}).values():
                    schema = resolve(document, media["schema"])
                    Draft202012Validator.check_schema(schema)
                    validator = Draft202012Validator(schema)
                    for example in media.get("examples", {}).values():
                        validator.validate(resolve(document, example)["value"])
                        count += 1
    if count == 0:
        raise ValueError("Contract has no verifiable response examples")
    return count


if __name__ == "__main__":
    print(f"OpenAPI schema and {validate_contract(load_contract())} response examples verified.")
