import math
from pathlib import Path

import pytest

from annotation_data.jsonl import read_jsonl, write_jsonl_atomic


def test_jsonl_round_trip_and_invalid_line_number(tmp_path: Path) -> None:
    path = tmp_path / "records.jsonl"
    records = [{"frame": 0}, {"frame": 1}]
    write_jsonl_atomic(path, records)
    assert read_jsonl(path) == records
    path.write_text('{"frame": 0}\nnot-json\n', encoding="utf-8")
    with pytest.raises(ValueError, match=f"{path}:2:"):
        read_jsonl(path)


def test_jsonl_rejects_non_finite_and_preserves_target(tmp_path: Path) -> None:
    invalid_input = tmp_path / "invalid.jsonl"
    invalid_input.write_text('{"value": Infinity}\n', encoding="utf-8")
    with pytest.raises(ValueError, match="non-finite JSON constant"):
        read_jsonl(invalid_input)
    target = tmp_path / "records.jsonl"
    target.write_text('{"existing": true}\n', encoding="utf-8")
    with pytest.raises(ValueError):
        write_jsonl_atomic(target, [{"value": math.nan}])
    assert target.read_text(encoding="utf-8") == '{"existing": true}\n'
    assert not target.with_suffix(".jsonl.tmp").exists()
