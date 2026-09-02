import json
from pathlib import Path

from annotool.contracts import (
    validate_annotation_semantics,
    validate_instance,
    validate_manifest_semantics,
)
from annotool.jsonl import read_jsonl, write_jsonl_atomic
from validate_annotations import main


FIXTURES = Path("core/fixtures")


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_valid_box_annotation_passes() -> None:
    errors = validate_instance(
        load(FIXTURES / "valid/annotation-box.json"),
        "annotation-v1.schema.json",
    )
    assert errors == []


def test_negative_box_width_is_rejected() -> None:
    errors = validate_instance(
        load(FIXTURES / "invalid/annotation-negative-width.json"),
        "annotation-v1.schema.json",
    )
    assert any("exclusiveMinimum" in error or "greater than 0" in error for error in errors)


def test_region_cannot_have_box_and_polygon() -> None:
    errors = validate_instance(
        load(FIXTURES / "invalid/annotation-both-geometries.json"),
        "annotation-v1.schema.json",
    )
    assert errors


def test_fixed_geometry_and_image_size_tuples_require_all_values() -> None:
    record = load(FIXTURES / "valid/annotation-box.json")
    record["image_size"] = [640]
    record["regions"][0]["box"] = [10, 20, 40]

    errors = validate_instance(record, "annotation-v1.schema.json")

    assert any("image_size" in error for error in errors)
    assert any("regions.0.box" in error for error in errors)


def test_valid_manifest_passes_schema_and_semantics() -> None:
    manifest = load(FIXTURES / "valid/dataset-manifest.json")
    assert validate_instance(manifest, "dataset-manifest-v1.schema.json") == []
    assert validate_manifest_semantics(manifest) == []


def test_manifest_frame_gap_is_rejected_semantically() -> None:
    errors = validate_manifest_semantics(
        load(FIXTURES / "invalid/manifest-frame-gap.json")
    )
    assert any("frames.1.frame" in error for error in errors)


def test_annotation_semantics_reject_duplicate_ids_and_out_of_bounds_geometry() -> None:
    record = load(FIXTURES / "valid/annotation-box.json")
    duplicate = dict(record["regions"][0])
    duplicate["box"] = [620, 20, 21, 30]
    record["regions"].append(duplicate)

    errors = validate_annotation_semantics(record)

    assert any("regions.1.id" in error for error in errors)
    assert any("regions.1.box" in error for error in errors)


def test_annotation_semantics_rejects_polygon_vertex_at_image_boundary() -> None:
    record = load(FIXTURES / "valid/annotation-polygon.json")
    record["regions"][0]["polygon"][0] = [640, 10]

    errors = validate_annotation_semantics(record)

    assert any("regions.0.polygon.0" in error for error in errors)


def test_jsonl_helpers_round_trip_and_report_invalid_line(tmp_path: Path) -> None:
    path = tmp_path / "records.jsonl"
    records = [{"frame": 0}, {"frame": 1}]

    write_jsonl_atomic(path, records)

    assert read_jsonl(path) == records
    path.write_text('{"frame": 0}\nnot-json\n', encoding="utf-8")
    try:
        read_jsonl(path)
    except ValueError as error:
        assert f"{path}:2:" in str(error)
    else:
        raise AssertionError("Expected invalid JSONL to raise ValueError")


def test_cli_reports_non_object_jsonl_record_without_a_traceback(
    tmp_path: Path, capsys: object
) -> None:
    path = tmp_path / "invalid-record.jsonl"
    path.write_text("[1, 2]\n", encoding="utf-8")

    assert main([str(path)]) == 1

    output = capsys.readouterr().out  # type: ignore[attr-defined]
    assert "record 0: $:" in output
