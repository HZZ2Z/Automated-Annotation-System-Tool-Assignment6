import json
import math
from pathlib import Path

from annotation_data.contracts import validate_instance, validate_manifest_semantics


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests/fixtures/dataset_manifest_v1"


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_valid_manifest_passes_schema_and_semantics() -> None:
    manifest = load(FIXTURES / "valid/dataset-manifest.json")
    assert validate_instance(manifest, "dataset-manifest-v1.schema.json") == []
    assert validate_manifest_semantics(manifest) == []


def test_manifest_frame_gap_is_rejected_semantically() -> None:
    errors = validate_manifest_semantics(
        load(FIXTURES / "invalid/manifest-frame-gap.json")
    )
    assert any("frames.1.frame" in error for error in errors)


def test_manifest_similarity_scores_must_be_finite_and_match_transitions() -> None:
    manifest = load(FIXTURES / "valid/dataset-manifest.json")
    manifest["similarity_scores"] = [0.01]

    assert validate_instance(manifest, "dataset-manifest-v1.schema.json") == []
    assert validate_manifest_semantics(manifest) == []

    manifest["similarity_scores"] = []
    assert any(
        "similarity_scores" in error
        for error in validate_manifest_semantics(manifest)
    )

    manifest["similarity_scores"] = [math.nan]
    assert any(
        "similarity_scores.0" in error
        for error in validate_manifest_semantics(manifest)
    )


def test_manifest_semantics_compares_integral_float_frame_count() -> None:
    manifest = load(FIXTURES / "valid/dataset-manifest.json")
    manifest["frame_count"] = 3.0

    schema_errors = validate_instance(manifest, "dataset-manifest-v1.schema.json")
    errors = validate_manifest_semantics(manifest)

    assert schema_errors == []
    assert any("expected 2 entries" in error for error in errors)


def test_manifest_accepts_integral_float_frame_count() -> None:
    manifest = load(FIXTURES / "valid/dataset-manifest.json")
    manifest["frame_count"] = 2.0

    schema_errors = validate_instance(manifest, "dataset-manifest-v1.schema.json")
    semantic_errors = validate_manifest_semantics(manifest)

    assert schema_errors == []
    assert semantic_errors == []


def test_manifest_rejects_boolean_frame_count() -> None:
    manifest = load(FIXTURES / "valid/dataset-manifest.json")
    manifest["frame_count"] = True
    manifest["frames"] = manifest["frames"][:1]

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

        assert validate_instance(
            manifest, "dataset-manifest-v1.schema.json"
        ), image_path
