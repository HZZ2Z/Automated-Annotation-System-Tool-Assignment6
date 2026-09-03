import json
from copy import deepcopy
from pathlib import Path

import pytest

from annotool.contracts import validate_instance


ROOT = Path(__file__).resolve().parents[2]
VALID = ROOT / "core/fixtures/valid"
INVALID = ROOT / "core/fixtures/invalid"
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
