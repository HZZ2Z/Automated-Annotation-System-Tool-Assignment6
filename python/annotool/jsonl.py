"""JSON Lines reading and crash-safe writing helpers."""

import json
import os
from pathlib import Path
from typing import Iterable


def read_jsonl(path: Path) -> list[dict]:
    """Read non-blank JSONL records and identify malformed input lines."""
    records: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if line.strip():
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError as error:
                    raise ValueError(f"{path}:{line_number}: {error.msg}") from error
    return records


def write_jsonl_atomic(path: Path, records: Iterable[dict]) -> None:
    """Write records to a sibling temporary file, then atomically replace ``path``."""
    temp_path = path.with_suffix(path.suffix + ".tmp")
    with temp_path.open("w", encoding="utf-8", newline="\n") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    temp_path.replace(path)
