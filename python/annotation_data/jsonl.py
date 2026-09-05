"""JSON Lines reading and crash-safe writing helpers."""

import json
import os
from pathlib import Path
from typing import Iterable


def reject_non_finite_constant(value: str) -> None:
    """Reject JSON's non-standard NaN and Infinity constants."""
    raise ValueError(f"non-finite JSON constant {value!r}")


def read_jsonl(path: Path) -> list[dict]:
    """Read non-blank JSONL records and identify malformed input lines."""
    records: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if line.strip():
                try:
                    records.append(json.loads(line, parse_constant=reject_non_finite_constant))
                except json.JSONDecodeError as error:
                    raise ValueError(f"{path}:{line_number}: {error.msg}") from error
                except ValueError as error:
                    raise ValueError(f"{path}:{line_number}: {error}") from error
    return records


def write_jsonl_atomic(path: Path, records: Iterable[dict]) -> None:
    """Write records to a sibling temporary file, then atomically replace ``path``."""
    temp_path = path.with_suffix(path.suffix + ".tmp")
    try:
        with temp_path.open("w", encoding="utf-8", newline="\n") as handle:
            for record in records:
                handle.write(
                    json.dumps(record, ensure_ascii=False, sort_keys=True, allow_nan=False) + "\n"
                )
            handle.flush()
            os.fsync(handle.fileno())
        temp_path.replace(path)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise
