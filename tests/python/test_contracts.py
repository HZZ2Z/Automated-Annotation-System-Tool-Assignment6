import json
import math
from pathlib import Path

import pytest

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


def test_manifest_semantics_compares_integral_float_frame_count() -> None:
    manifest = load(FIXTURES / "valid/dataset-manifest.json")
    manifest["frame_count"] = 3.0

    schema_errors = validate_instance(manifest, "dataset-manifest-v1.schema.json")
    errors = validate_manifest_semantics(manifest)

    assert any(error.startswith("frame_count:") for error in schema_errors)
    assert any(error.startswith("frame_count:") for error in errors)


@pytest.mark.parametrize(
    ("frame_count", "frame_entries"),
    [(2.0, 2), (True, 1)],
)
def test_manifest_requires_an_exact_integer_frame_count(
    frame_count: int | float | bool, frame_entries: int
) -> None:
    manifest = load(FIXTURES / "valid/dataset-manifest.json")
    manifest["frame_count"] = frame_count
    manifest["frames"] = manifest["frames"][:frame_entries]

    schema_errors = validate_instance(manifest, "dataset-manifest-v1.schema.json")
    semantic_errors = validate_manifest_semantics(manifest)

    assert any(error.startswith("frame_count:") for error in schema_errors)
    assert any(error.startswith("frame_count:") for error in semantic_errors)


def test_manifest_schema_rejects_non_relative_image_paths() -> None:
    invalid_paths = [
        "/frames/frame_000000.png",
        "C:\\frames\\frame_000000.png",
        "\\\\server\\share\\frame_000000.png",
        "frames\\..\\frame_000000.png",
        "https://example.invalid/frame_000000.png",
        "frames/../frame_000000.png",
    ]
    for image_path in invalid_paths:
        manifest = load(FIXTURES / "valid/dataset-manifest.json")
        manifest["frames"][0]["image_path"] = image_path

        assert validate_instance(manifest, "dataset-manifest-v1.schema.json"), image_path


def test_annotation_semantics_checks_duplicate_ids_without_valid_image_size() -> None:
    record = load(FIXTURES / "valid/annotation-box.json")
    record["image_size"] = [640]
    record["regions"].append(dict(record["regions"][0]))

    errors = validate_annotation_semantics(record)

    assert any("regions.1.id" in error for error in errors)


def test_jsonl_rejects_non_finite_constants_and_preserves_existing_target(
    tmp_path: Path,
) -> None:
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


def test_cli_rejects_non_finite_single_json_without_traceback(
    tmp_path: Path, capsys: object
) -> None:
    path = tmp_path / "invalid.json"
    path.write_text('{"value": NaN}', encoding="utf-8")

    assert main([str(path)]) == 1

    output = capsys.readouterr().out  # type: ignore[attr-defined]
    assert "non-finite JSON constant" in output


def test_annotation_source_rejects_terminal_newline() -> None:
    record = load(FIXTURES / "valid/annotation-box.json")
    record["source"] = "human_corrected\n"

    errors = validate_instance(record, "annotation-v1.schema.json")

    assert any(error.startswith("source:") for error in errors)
