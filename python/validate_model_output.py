"""Part 1.1 read-only Model Output V1 validator facade and CLI.

The JSON Schema in ``core/schemas/model_output_v1.schema.json`` is the sole
contract authority. This module exposes stable validation helpers and converts
file, JSON, and schema failures into field-specific messages without modifying
input or leaking a traceback from expected CLI errors.
"""

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

from annotation_data.contracts import load_schema as load_named_schema
from annotation_data.contracts import validate_instance
from annotation_data.jsonl import read_jsonl, reject_non_finite_constant


SCHEMA_NAME = "model_output_v1.schema.json"


def load_schema() -> dict[str, Any]:
    """Return the sole authoritative Model Output V1 JSON Schema.

    This stable facade keeps callers independent of package-internal schema
    lookup while ensuring every validator uses the same contract authority.
    """
    return load_named_schema(SCHEMA_NAME)


def validate_record(record: object) -> list[str]:
    """Validate one record and return field-path errors, or ``[]`` if valid.

    The record is inspected only; this read-only helper never normalizes or
    mutates model output before passing it to the canonical schema validator.
    """
    return validate_instance(record, SCHEMA_NAME)


def _load_records(path: Path) -> list[object]:
    """Load one JSON record or ordered JSONL records without writing ``path``.

    Plain JSON contributes exactly one record. JSONL is read line by line in
    file order so downstream error indices identify the original record order.
    """
    if path.suffix.lower() == ".jsonl":
        return list(read_jsonl(path))
    payload = json.loads(
        path.read_text(encoding="utf-8"),
        parse_constant=reject_non_finite_constant,
    )
    return [payload]


def validate_model_output(path: Path) -> list[str]:
    """Validate a read-only JSON or JSONL input and return record-indexed errors.

    JSON produces one record, while JSONL preserves line order. File and parse
    failures are returned as messages; schema failures are prefixed with their
    zero-based record index so callers can locate invalid model output exactly.
    """
    try:
        records = _load_records(path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return [f"{path}: {error}"]
    return [
        f"record {index}: {error}"
        for index, record in enumerate(records)
        for error in validate_record(record)
    ]


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the single read-only model-output path accepted by the CLI."""
    parser = argparse.ArgumentParser(
        description="Validate Model Output V1 JSON or JSONL."
    )
    parser.add_argument("path", type=Path, help="model output JSON or JSONL path")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Print validation errors for expected CLI failures and return ``0`` or ``1``.

    Successful validation prints the fixed zero-error message and returns ``0``;
    unreadable, malformed, or schema-invalid input prints its returned errors
    and returns ``1`` without exposing an expected-error traceback.
    """
    args = parse_args(argv)
    errors = validate_model_output(args.path)
    if errors:
        for error in errors:
            print(error)
        return 1
    print("Validation errors: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
