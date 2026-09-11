from __future__ import annotations

import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
import pytest

from annotation_data.contracts import validate_instance
from annotation_data.endoscapes_fixture import BuildRequest, build_fixture


def _dataset(root: Path, *, count: int = 5) -> Path:
    (root / "train").mkdir(parents=True)
    (root / "insseg").mkdir()
    for index in range(count):
        frame = 100 + index * 25
        image = np.full((32, 48, 3), (index * 7, 20, 40), np.uint8)
        assert cv2.imwrite(str(root / "train" / f"7_{frame}.jpg"), image)
    mask = np.zeros((2, 32, 48), np.uint8)
    mask[0, 0:20, 5:30] = 1  # valid after the explicit boundary inset
    mask[1, 10:20, 32:42] = 1
    np.save(root / "insseg" / "7_125.npy", mask)
    np.savetxt(root / "insseg" / "7_125.csv", np.array([5, 6]), fmt="%d")
    return root


def _request(dataset: Path, output: Path, **changes: object) -> BuildRequest:
    values = dict(dataset_root=dataset, output=output, video_id=7,
                  start_frame=100, end_frame=200, key_frame=125,
                  instance_index=0, copy_images=False)
    values.update(changes)
    return BuildRequest(**values)


def test_builds_contiguous_source_with_provenance_and_v1_polygon(tmp_path: Path) -> None:
    dataset = _dataset(tmp_path / "dataset")
    before = {p.relative_to(dataset): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in dataset.rglob("*") if p.is_file()}
    output = tmp_path / "fixture"

    summary = build_fixture(_request(dataset, output))

    manifest = json.loads((output / "manifest.json").read_text())
    records = [json.loads(line) for line in
               (output / "model_output_v1.jsonl").read_text().splitlines()]
    provenance = json.loads((output / "provenance.json").read_text())
    assert [entry["frame"] for entry in manifest["frames"]] == list(range(5))
    assert [record["frame"] for record in records] == list(range(5))
    assert [entry["original_frame_id"] for entry in provenance["frames"]] == [100, 125, 150, 175, 200]
    assert len(records[1]["regions"]) == 1
    assert records[1]["regions"][0]["class"] == "gallbladder"
    assert records[1]["regions"][0]["kind"] == "anatomy"
    assert records[0]["regions"] == [] and records[2]["regions"] == []
    assert provenance["keyframe_seed"]["boundary_inset_pixels"] == 2
    assert provenance["keyframe_seed"]["category_id"] == 5
    assert provenance["keyframe_seed"]["lossless"] is False
    assert provenance["keyframe_seed"]["retained_iou"] >= 0.90
    assert summary["key_playback_index"] == 1
    assert validate_instance(manifest, "dataset-manifest-v1.schema.json") == []
    assert all(validate_instance(record, "model_output_v1.schema.json") == [] for record in records)
    for index, frame in enumerate([100, 125, 150, 175, 200]):
        link = output / manifest["frames"][index]["image_path"]
        assert link.is_symlink() and link.resolve() == dataset / "train" / f"7_{frame}.jpg"
    after = {p.relative_to(dataset): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in dataset.rglob("*") if p.is_file()}
    assert after == before


@pytest.mark.parametrize("count", [4, 31])
def test_refuses_outside_five_to_thirty_frame_bound(count: int, tmp_path: Path) -> None:
    dataset = _dataset(tmp_path / "dataset", count=count)
    with pytest.raises(ValueError, match="5 to 30"):
        build_fixture(_request(dataset, tmp_path / "fixture", end_frame=100 + (count - 1) * 25))
    assert not (tmp_path / "fixture").exists()


def test_refuses_missing_duplicate_bad_counts_selection_and_collision(tmp_path: Path) -> None:
    dataset = _dataset(tmp_path / "dataset")
    (dataset / "train" / "7_150.jpg").unlink()
    with pytest.raises(ValueError, match="missing frame"):
        build_fixture(_request(dataset, tmp_path / "missing"))
    assert not (tmp_path / "missing").exists()

    assert cv2.imwrite(str(dataset / "train" / "7_150.jpg"), np.zeros((32, 48, 3), np.uint8))
    duplicate = dataset / "train" / "nested"
    duplicate.mkdir()
    assert cv2.imwrite(str(duplicate / "7_150.jpg"), np.zeros((32, 48, 3), np.uint8))
    with pytest.raises(ValueError, match="duplicate frame"):
        build_fixture(_request(dataset, tmp_path / "duplicate"))
    (duplicate / "7_150.jpg").unlink()

    np.savetxt(dataset / "insseg" / "7_125.csv", np.array([5]), fmt="%d")
    with pytest.raises(ValueError, match="mask/CSV count"):
        build_fixture(_request(dataset, tmp_path / "counts"))
    np.savetxt(dataset / "insseg" / "7_125.csv", np.array([5, 6]), fmt="%d")
    with pytest.raises(ValueError, match="instance index"):
        build_fixture(_request(dataset, tmp_path / "selection", instance_index=2))

    collision = tmp_path / "collision"
    collision.mkdir()
    with pytest.raises(ValueError, match="already exists"):
        build_fixture(_request(dataset, collision))


def test_refuses_non_step_range_invalid_keyframe_and_unsafe_polygon(tmp_path: Path) -> None:
    dataset = _dataset(tmp_path / "dataset")
    with pytest.raises(ValueError, match="multiples of 25"):
        build_fixture(_request(dataset, tmp_path / "step", end_frame=199))
    with pytest.raises(ValueError, match="key frame"):
        build_fixture(_request(dataset, tmp_path / "key", key_frame=225))

    mask = np.load(dataset / "insseg" / "7_125.npy")
    mask[0] = 0
    mask[0, 5:13, 5:13] = 1
    mask[0, 19:27, 30:38] = 1
    np.save(dataset / "insseg" / "7_125.npy", mask)
    with pytest.raises(ValueError, match="multiple components"):
        build_fixture(_request(dataset, tmp_path / "topology"))
    assert not (tmp_path / "topology").exists()
