import importlib
import json
from pathlib import Path

from annotation_data.contracts import validate_instance


ROOT = Path(__file__).resolve().parents[2]
MEDIA_LABEL_FIXTURES = ROOT / "tests/fixtures/media_label_v1"


def _workspace_module():
    return importlib.import_module("annotation_data.workspace")


def _valid_media_label() -> dict:
    return {
        "schema_version": 1,
        "media_id": "VID68",
        "media_type": "image_sequence",
        "source_relative_path": "videos/VID68",
        "source_sha256": None,
        "frame_digits": 6,
        "frames": {
            "16": {
                "schema_version": 1,
                "source": "VID68",
                "frame": 16,
                "time_s": 16.0,
                "regions": [],
            },
            "23": {
                "schema_version": 1,
                "source": "VID68",
                "frame": 23,
                "time_s": 23.0,
                "regions": [],
            },
        },
    }


def test_portable_media_id_preserves_dataset_id_and_normalizes_separators() -> None:
    workspace = _workspace_module()

    assert workspace.portable_media_id("VID68") == "VID68"
    assert workspace.portable_media_id("Operation 01") == "Operation_01"
    # Non-ASCII characters are separators, not transliterated differently by runtime.
    assert workspace.portable_media_id("Café") == "Caf"
    assert workspace.portable_media_id("术野") == "media"
    assert workspace.portable_media_id("A" * 63 + " B") == "A" * 63


def test_sample_id_combines_media_and_original_six_digit_frame() -> None:
    workspace = _workspace_module()

    assert workspace.sample_id("VID68", 16) == "VID68_000016"


def test_label_path_is_one_json_directly_under_workspace_label(tmp_path) -> None:
    workspace = _workspace_module()

    assert workspace.label_path(tmp_path, "VID68") == tmp_path / "label/VID68.json"


def test_valid_single_file_media_label_passes_schema_and_semantics() -> None:
    workspace = _workspace_module()
    value = _valid_media_label()

    assert validate_instance(value, "media-label-v1.schema.json") == []
    assert workspace.validate_media_label_semantics(value) == []


def test_frame_dictionary_key_must_match_model_output_frame() -> None:
    workspace = _workspace_module()
    value = _valid_media_label()
    value["frames"]["16"]["frame"] = 17

    errors = workspace.validate_media_label_semantics(value)

    assert any(error.startswith("frames.16.frame:") for error in errors)


def test_native_file_distinguishes_absent_frame_from_explicit_negative() -> None:
    workspace = _workspace_module()
    value = _valid_media_label()
    del value["frames"]["23"]

    assert workspace.validate_media_label_semantics(value) == []
    assert "23" not in value["frames"]
    assert value["frames"]["16"]["regions"] == []


def test_media_label_contract_fixtures_exercise_schema_and_semantics() -> None:
    workspace = _workspace_module()
    valid = json.loads(
        (MEDIA_LABEL_FIXTURES / "valid/media-label.json").read_text(encoding="utf-8")
    )
    invalid = json.loads(
        (MEDIA_LABEL_FIXTURES / "invalid/media-label-frame-mismatch.json").read_text(
            encoding="utf-8"
        )
    )

    assert validate_instance(valid, "media-label-v1.schema.json") == []
    assert workspace.validate_media_label_semantics(valid) == []
    assert validate_instance(invalid, "media-label-v1.schema.json") == []
    assert workspace.validate_media_label_semantics(invalid) == [
        "frames.16.frame: expected frame 16, got 17"
    ]


def test_v2_review_and_batch_metadata_contract() -> None:
    value = _valid_media_label()
    value.update(schema_version=2, review_state={"16": {"accepted_digest": "a" * 64}}, batch_operations=[])
    assert validate_instance(value, "media-label-v2.schema.json") == []
    value["review_state"]["16"]["accepted_digest"] = "invalid"
    assert validate_instance(value, "media-label-v2.schema.json")


def test_v2_batch_marker_requires_unique_targets() -> None:
    value = _valid_media_label()
    value.update(schema_version=2, review_state={}, batch_operations=[{
        "schema_version": 1, "type": "range_propagate", "mode": "overwrite",
        "keyframe": 16, "start_frame": 16, "end_frame": 23, "affected_frames": [23, 23]
    }])
    assert validate_instance(value, "media-label-v2.schema.json")


def test_v2_audit_fields_validate_when_present() -> None:
    value = _valid_media_label()
    marker = {
        "schema_version": 1, "type": "range_propagate", "mode": "overwrite",
        "keyframe": 16, "start_frame": 16, "end_frame": 23, "affected_frames": [23],
        "metric_id": "gray_mad", "threshold": 0.02, "max_frames": 30,
        "keyframe_digest": "a" * 64, "created_at": "2026-09-07T01:02:03",
        "start_index": 0, "end_index": 1, "changed_count": 1, "covered_count": 2,
        "left_stop": "boundary", "right_stop": "boundary",
    }
    value.update(schema_version=2, review_state={}, batch_operations=[marker])
    assert validate_instance(value, "media-label-v2.schema.json") == []
    for key, invalid in [("metric_id", ""), ("threshold", 0), ("max_frames", 1.5),
                         ("keyframe_digest", "bad"), ("created_at", "yesterday")]:
        original = marker[key]
        marker[key] = invalid
        assert validate_instance(value, "media-label-v2.schema.json"), key
        marker[key] = original
    del marker["threshold"]
    assert validate_instance(value, "media-label-v2.schema.json")
