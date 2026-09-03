import hashlib
import json
from pathlib import Path
import subprocess
import sys

import cv2
import numpy as np
import pytest

from annotool.contracts import (
    validate_instance,
    validate_manifest_semantics,
)
from annotool.jsonl import read_jsonl
from annotool.sample import generate_sample
from annotool.similarity import contiguous_run
from validate_model_output import validate_model_output


ROOT = Path(__file__).resolve().parents[2]
EXPECTED_DEFECTS = ROOT / "tests/expected/sample-defects.json"


@pytest.fixture(scope="module")
def samples(tmp_path_factory: pytest.TempPathFactory) -> tuple[Path, dict[str, str], Path]:
    root = tmp_path_factory.mktemp("sample-generation")
    first_dir = root / "first"
    second_dir = root / "second"
    first_hashes = generate_sample(first_dir, seed=6006)
    second_hashes = generate_sample(second_dir, seed=6006)
    assert first_hashes == second_hashes
    return first_dir, first_hashes, second_dir


def test_sample_is_deterministic(samples: tuple[Path, dict[str, str], Path]) -> None:
    first_dir, first_hashes, second_dir = samples
    assert json.loads((first_dir / "hashes.json").read_text(encoding="utf-8")) == first_hashes
    assert json.loads((second_dir / "hashes.json").read_text(encoding="utf-8")) == first_hashes
    assert "model_output_v1.jsonl" in first_hashes
    assert "model_output.jsonl" not in first_hashes
    assert not (first_dir / "model_output.jsonl").exists()
    for relative_path, digest in first_hashes.items():
        assert hashlib.sha256((first_dir / relative_path).read_bytes()).hexdigest() == digest


def test_sample_model_output_matches_assignment_contract(
    samples: tuple[Path, dict[str, str], Path],
) -> None:
    sample_dir, _, _ = samples
    frame_paths = sorted((sample_dir / "frames").glob("*.png"))
    assert [path.name for path in frame_paths] == [
        f"frame_{frame:06d}.png" for frame in range(120)
    ]
    assert all(cv2.imread(str(path)).shape == (360, 640, 3) for path in frame_paths)

    manifest = json.loads((sample_dir / "manifest.json").read_text(encoding="utf-8"))
    assert validate_instance(manifest, "dataset-manifest-v1.schema.json") == []
    assert validate_manifest_semantics(manifest) == []
    assert (manifest["frame_count"], manifest["width"], manifest["height"]) == (
        120,
        640,
        360,
    )
    assert manifest["nominal_fps"] == 30.0
    assert len(manifest["similarity_scores"]) == 119
    assert all(0.0 <= score <= 1.0 for score in manifest["similarity_scores"])

    model_path = sample_dir / "model_output_v1.jsonl"
    assert validate_model_output(model_path) == []
    records = read_jsonl(model_path)
    assert len(records) == 120
    region_counts = []
    for frame, record in enumerate(records):
        assert record["schema_version"] == 1
        assert record["source"] == "sample_v1"
        assert record["frame"] == frame
        assert set(record) == {"schema_version", "source", "frame", "time_s", "regions"}
        assert all("filled" not in region for region in record["regions"])
        assert "dataset_id" not in record
        assert "image_size" not in record
        region_counts.append(len(record["regions"]))
    assert set(region_counts) == {19, 20, 21}
    assert all(19 <= count <= 21 for count in region_counts)
    assert not any(sample_dir.glob("*ground_truth*"))
    assert manifest["source_name"] == "sample_v1"
    assert manifest["model_version"] == "model_output_v1"


def test_sample_contains_required_defects(
    samples: tuple[Path, dict[str, str], Path],
) -> None:
    sample_dir, _, _ = samples
    defects = json.loads((sample_dir / "expected_defects.json").read_text(encoding="utf-8"))
    expected = json.loads(EXPECTED_DEFECTS.read_text(encoding="utf-8"))
    assert defects == expected
    assert set(defects["types"]) == {
        "drift",
        "wrong_class",
        "missed_region",
        "hallucinated_region",
        "track_id_swap",
    }
    assert defects["similar_run"] == [40, 59]

    records = {
        record["frame"]: record
        for record in read_jsonl(sample_dir / "model_output_v1.jsonl")
    }
    by_id = {
        frame: {region["id"]: region for region in record["regions"]}
        for frame, record in records.items()
    }
    for defect in defects["defects"]:
        frame = defect["frame"]
        if defect["type"] == "drift":
            assert by_id[frame][defect["region_id"]]["box"] == defect["model_box"]
            assert defect["model_box"] != defect["expected_box"]
        elif defect["type"] == "wrong_class":
            assert by_id[frame][defect["region_id"]]["class"] == defect["model_class"]
            assert defect["model_class"] != defect["expected_class"]
        elif defect["type"] == "missed_region":
            assert defect["region_id"] not in by_id[frame]
        elif defect["type"] == "hallucinated_region":
            assert by_id[frame][defect["region_id"]] == defect["model_region"]
        elif defect["type"] == "track_id_swap":
            assert {
                region_id: by_id[frame][region_id]["track_id"]
                for region_id in defect["region_ids"]
            } == defect["model_track_ids"]


def test_similar_run_is_near_identical_with_distinguishable_boundaries(
    samples: tuple[Path, dict[str, str], Path],
) -> None:
    sample_dir, _, _ = samples

    manifest = json.loads((sample_dir / "manifest.json").read_text(encoding="utf-8"))
    scores = manifest["similarity_scores"]

    assert contiguous_run(scores, keyframe=50, threshold=0.02) == (40, 59)
    assert scores[39] >= 0.02
    assert scores[59] >= 0.02


def test_cli_rejects_existing_directory_without_overwriting(tmp_path: Path) -> None:
    output_dir = tmp_path / "existing"
    output_dir.mkdir()
    sentinel = output_dir / "keep.txt"
    sentinel.write_text("keep", encoding="utf-8")

    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "python/make_sample_input.py"),
            "--output",
            str(output_dir),
            "--seed",
            "6006",
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert "already exists" in result.stderr
    assert "Traceback" not in result.stderr
    assert sentinel.read_text(encoding="utf-8") == "keep"
    assert list(output_dir.iterdir()) == [sentinel]
