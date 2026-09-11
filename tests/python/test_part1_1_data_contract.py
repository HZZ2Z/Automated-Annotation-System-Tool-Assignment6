import json
import hashlib
import subprocess
import sys
from copy import deepcopy
from pathlib import Path

import pytest

from annotation_data.contracts import validate_instance
from validate_model_output import (
    load_schema,
    main,
    validate_model_output,
    validate_record,
)


ROOT = Path(__file__).resolve().parents[2]
VALID = ROOT / "tests/fixtures/model_output_v1/valid"
INVALID = ROOT / "tests/fixtures/model_output_v1/invalid"
SCHEMA = "model_output_v1.schema.json"


def load(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def validate(record: object) -> list[str]:
    return validate_instance(record, SCHEMA)


def test_assignment_example_is_preserved_and_valid() -> None:
    record = load(VALID / "assignment-model-output-v1.json")
    assert record == {
        "schema_version": 1,
        "source": "sample_v1",
        "frame": 128,
        "time_s": 4.27,
        "regions": [
            {
                "id": "reg-003",
                "class": "grasper",
                "kind": "instrument",
                "box": [585, 26, 268, 176],
                "polygon": [[585, 26], [853, 26], [853, 202], [585, 202]],
                "conf": 0.92,
                "track_id": "T02",
            },
            {
                "id": "reg-004",
                "class": "cystic_duct",
                "kind": "anatomy",
                "box": [361, 224, 254, 150],
                "conf": 0.87,
                "track_id": None,
            },
        ],
    }
    assert validate(record) == []


@pytest.mark.parametrize(
    "name",
    [
        "model-output-v1-box-only.json",
        "model-output-v1-integral-numbers.json",
        "model-output-v1-polygon-only.json",
        "model-output-v1-empty-regions.json",
    ],
)
def test_valid_shared_fixtures_pass(name: str) -> None:
    assert validate(load(VALID / name)) == []


@pytest.mark.parametrize("path", sorted(INVALID.glob("model-output-v1-*.json")))
def test_invalid_shared_fixtures_fail(path: Path) -> None:
    assert validate(load(path)), path.name


def test_box_and_polygon_may_appear_together() -> None:
    record = load(VALID / "model-output-v1-box-only.json")
    record["regions"][0]["polygon"] = [
        [10, 20],
        [50, 20],
        [50, 50],
        [10, 50],
    ]
    assert validate(record) == []


def test_kind_is_open_non_empty_text() -> None:
    record = load(VALID / "model-output-v1-box-only.json")
    record["regions"][0]["kind"] = "future_custom_kind"
    assert validate(record) == []
    record["regions"][0]["kind"] = ""
    assert any(error.startswith("regions.0.kind:") for error in validate(record))


@pytest.mark.parametrize("field", ["schema_version", "source", "frame", "regions"])
def test_required_top_level_fields_have_paths(field: str) -> None:
    record = load(VALID / "model-output-v1-box-only.json")
    del record[field]
    assert any(error.startswith(f"{field}:") for error in validate(record))


def test_assignment_does_not_add_project_only_fields() -> None:
    for field, value in (
        ("dataset_id", "dataset"),
        ("image_size", [640, 360]),
        ("filled", False),
    ):
        record = deepcopy(load(VALID / "model-output-v1-box-only.json"))
        if field == "filled":
            record["regions"][0][field] = value
            expected_path = "regions.0.filled:"
        else:
            record[field] = value
            expected_path = f"{field}:"
        assert any(error.startswith(expected_path) for error in validate(record))


def test_validator_public_api_uses_v1_schema() -> None:
    assert load_schema()["$id"] == "model_output_v1.schema.json"
    record = load(VALID / "assignment-model-output-v1.json")
    assert validate_record(record) == []


def test_jsonl_errors_include_record_index_and_field_path(tmp_path: Path) -> None:
    valid = load(VALID / "model-output-v1-box-only.json")
    invalid = deepcopy(valid)
    del invalid["regions"][0]["class"]
    path = tmp_path / "model_output_v1.jsonl"
    path.write_text(
        json.dumps(valid) + "\n" + json.dumps(invalid) + "\n",
        encoding="utf-8",
    )
    errors = validate_model_output(path)
    assert any(error.startswith("record 1: regions.0.class:") for error in errors)


@pytest.mark.parametrize("constant", ["NaN", "Infinity", "-Infinity"])
def test_non_finite_json_is_rejected_without_traceback(
    tmp_path: Path, constant: str
) -> None:
    path = tmp_path / "model_output_v1.jsonl"
    path.write_text(
        '{"schema_version":1,"source":"sample_v1","frame":0,'
        f'"time_s":{constant},"regions":[]}}\n',
        encoding="utf-8",
    )
    result = subprocess.run(
        [sys.executable, str(ROOT / "python/validate_model_output.py"), str(path)],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1
    assert "non-finite JSON constant" in result.stdout
    assert "Traceback" not in result.stdout + result.stderr


def test_validator_does_not_modify_model_file(tmp_path: Path) -> None:
    source = VALID / "assignment-model-output-v1.json"
    path = tmp_path / "model_output_v1.json"
    path.write_bytes(source.read_bytes())
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    assert validate_model_output(path) == []
    after = hashlib.sha256(path.read_bytes()).hexdigest()
    assert after == before


def test_main_returns_one_for_malformed_json_and_no_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "model_output_v1.json"
    path.write_text("{bad", encoding="utf-8")
    assert main([str(path)]) == 1
    captured = capsys.readouterr()
    assert str(path) in captured.out
    assert "Traceback" not in captured.out + captured.err


def test_part1_1_schema_directory_has_only_model_output_v1() -> None:
    schema_files = sorted((ROOT / "core/schemas").glob("*.json"))
    assert [path.name for path in schema_files] == ["model_output_v1.schema.json"]


def test_removed_contract_aliases_do_not_exist() -> None:
    removed = [
        ROOT / "core/schemas/annotation-v1.schema.json",
        ROOT / "core/schemas/review-state-v1.schema.json",
        ROOT / "python/validate_annotations.py",
        ROOT / "client/domain/annotation_validator.gd",
    ]
    assert not [path for path in removed if path.exists()]
