"""Validate Model Output V1 JSON/JSONL without modifying the input file."""

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

from annotool.contracts import load_schema as load_named_schema
from annotool.contracts import validate_instance
from annotool.jsonl import read_jsonl, reject_non_finite_constant


SCHEMA_NAME = "model_output_v1.schema.json"


def load_schema() -> dict[str, Any]:
    """读取唯一的 Model Output V1 Schema。"""
    return load_named_schema(SCHEMA_NAME)


def validate_record(record: object) -> list[str]:
    """返回带字段路径的错误；空列表表示通过。"""
    return validate_instance(record, SCHEMA_NAME)


def _load_records(path: Path) -> list[object]:
    # JSONL 按行读取；普通 JSON 只包含一个 record。
    if path.suffix.lower() == ".jsonl":
        return list(read_jsonl(path))
    payload = json.loads(
        path.read_text(encoding="utf-8"),
        parse_constant=reject_non_finite_constant,
    )
    return [payload]


def validate_model_output(path: Path) -> list[str]:
    """校验单条 JSON 或逐行 JSONL，不向 path 写入任何内容。"""
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
    parser = argparse.ArgumentParser(
        description="Validate Model Output V1 JSON or JSONL."
    )
    parser.add_argument("path", type=Path, help="model output JSON or JSONL path")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
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
