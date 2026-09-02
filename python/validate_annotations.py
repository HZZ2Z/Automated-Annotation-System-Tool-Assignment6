"""Validate annotation JSON or JSONL files against the canonical contracts."""

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

from annotool.contracts import (
    validate_annotation_semantics,
    validate_instance,
    validate_manifest_semantics,
)
from annotool.jsonl import read_jsonl


DEFAULT_SCHEMA = "annotation-v1.schema.json"


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="JSON object or JSONL records to validate")
    parser.add_argument(
        "--schema",
        default=DEFAULT_SCHEMA,
        help="canonical schema filename (default: %(default)s)",
    )
    return parser.parse_args(argv)


def load_records(path: Path) -> list[dict]:
    if path.suffix.lower() == ".jsonl":
        return read_jsonl(path)
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected one JSON object")
    return [payload]


def record_errors(record: Any, schema_name: str) -> list[str]:
    errors = validate_instance(record, schema_name)
    if not isinstance(record, dict):
        return errors
    if schema_name == "annotation-v1.schema.json":
        errors.extend(validate_annotation_semantics(record))
    elif schema_name == "dataset-manifest-v1.schema.json":
        errors.extend(validate_manifest_semantics(record))
    return errors


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        records = load_records(args.path)
        errors = [
            f"record {index}: {error}"
            for index, record in enumerate(records)
            for error in record_errors(record, args.schema)
        ]
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(error)
        return 1

    for error in errors:
        print(error)
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
