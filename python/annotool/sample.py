"""Deterministic synthetic annotation sample generation."""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
from typing import Any

import cv2
import numpy as np

from annotool.contracts import (
    validate_instance,
    validate_manifest_semantics,
)
from annotool.jsonl import write_jsonl_atomic
from annotool.similarity import normalized_mad


FRAME_COUNT = 120
WIDTH = 640
HEIGHT = 360
FPS = 30.0
SIMILAR_START = 40
SIMILAR_END = 59

DATASET_ID = "annotool-sample"
SOURCE_ID = "sample_v1"
MODEL_VERSION = "model_output_v1"
TAXONOMY_VERSION = "sample-taxonomy-v1"

_REGION_CLASSES = (
    "grasper",
    "scissors",
    "gallbladder",
    "unknown",
    "cystic_duct",
    "grasper",
    "gallbladder",
    "scissors",
    "unknown",
    "cystic_duct",
    "scissors",
    "gallbladder",
    "grasper",
    "unknown",
    "cystic_duct",
    "scissors",
    "gallbladder",
    "unknown",
    "cystic_duct",
    "grasper",
)
_CLASS_KINDS = {
    "grasper": "instrument",
    "scissors": "instrument",
    "cystic_duct": "anatomy",
    "gallbladder": "anatomy",
    "unknown": "region",
}
_CLASS_COLORS_BGR = {
    "grasper": (68, 68, 239),
    "scissors": (11, 158, 245),
    "cystic_duct": (94, 197, 34),
    "gallbladder": (246, 130, 59),
    "unknown": (247, 85, 168),
}


def generate_sample(output_dir: Path, seed: int = 6006) -> dict[str, str]:
    """Generate the sample and return content hashes keyed by relative path."""
    rng = np.random.default_rng(seed)
    output_dir.mkdir(parents=True, exist_ok=False)
    frames_dir = output_dir / "frames"
    frames_dir.mkdir()

    color_jitter = rng.integers(-5, 6, size=(len(_REGION_CLASSES), 3))
    ground_truth: list[dict[str, Any]] = []
    frame_paths: list[Path] = []
    source_hasher = hashlib.sha256()
    similarity_scores: list[float] = []
    previous_image: np.ndarray | None = None

    for frame in range(FRAME_COUNT):
        regions = _clean_regions(frame, seed)
        image = _render_frame(frame, seed, regions, color_jitter)
        frame_path = frames_dir / f"frame_{frame:06d}.png"
        if not cv2.imwrite(str(frame_path), image):
            raise OSError(f"could not write frame {frame_path}")
        frame_bytes = frame_path.read_bytes()
        source_hasher.update(frame_bytes)
        frame_paths.append(frame_path)
        if previous_image is not None:
            similarity_scores.append(normalized_mad(previous_image, image))
        previous_image = image
        ground_truth.append(
            {
                "schema_version": 1,
                "source": SOURCE_ID,
                "frame": frame,
                "time_s": frame / FPS,
                "regions": regions,
            }
        )

    model_output = deepcopy(ground_truth)
    expected_defects = _plant_defects(model_output, ground_truth, seed)
    manifest = {
        "schema_version": 1,
        "dataset_id": DATASET_ID,
        "source_name": SOURCE_ID,
        "source_sha256": source_hasher.hexdigest(),
        "width": WIDTH,
        "height": HEIGHT,
        "frame_count": FRAME_COUNT,
        "nominal_fps": FPS,
        "frames": [
            {
                "frame": frame,
                "time_s": frame / FPS,
                "image_path": f"frames/frame_{frame:06d}.png",
            }
            for frame in range(FRAME_COUNT)
        ],
        "similarity_scores": similarity_scores,
        "model_version": MODEL_VERSION,
        "taxonomy_version": TAXONOMY_VERSION,
    }

    _validate_outputs(manifest, model_output)
    manifest_path = output_dir / "manifest.json"
    annotation_path = output_dir / f"{MODEL_VERSION}.jsonl"
    defects_path = output_dir / "expected_defects.json"
    _write_json(manifest_path, manifest)
    write_jsonl_atomic(annotation_path, model_output)
    _write_json(defects_path, expected_defects)

    hashed_paths = [*frame_paths, manifest_path, annotation_path, defects_path]
    hashes = {
        path.relative_to(output_dir).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in hashed_paths
    }
    hashes = dict(sorted(hashes.items()))
    _write_json(output_dir / "hashes.json", hashes)
    return hashes


def _clean_regions(frame: int, seed: int) -> list[dict[str, Any]]:
    motion_frame = SIMILAR_START if SIMILAR_START <= frame <= SIMILAR_END else frame
    regions: list[dict[str, Any]] = []
    for index, class_id in enumerate(_REGION_CLASSES):
        x = 35 + (index % 5) * 120 + ((motion_frame + index * 3 + seed) % 9) - 4
        y = 35 + (index // 5) * 75 + ((motion_frame * 2 + index * 5 + seed // 10) % 7) - 3
        width = 48 + (index % 3) * 4
        height = 34 + (index % 2) * 5
        region: dict[str, Any] = {
            "id": f"sample-r{index + 1:02d}",
            "class": class_id,
            "kind": _CLASS_KINDS[class_id],
            "conf": round(0.72 + (index % 7) * 0.035, 3),
            "track_id": f"sample-t{index + 1:02d}",
        }
        if index < 16:
            region["box"] = [x, y, width, height]
        else:
            region["polygon"] = [
                [x + width // 2, y],
                [x + width, y + height // 2],
                [x + width // 2, y + height],
                [x, y + height // 2],
            ]
        regions.append(region)
    return regions


def _render_frame(
    frame: int,
    seed: int,
    regions: list[dict[str, Any]],
    color_jitter: np.ndarray,
) -> np.ndarray:
    if SIMILAR_START <= frame <= SIMILAR_END:
        variation = (frame + seed) % 2
        background = np.array([24 + variation, 28 + variation, 32 + variation], dtype=np.uint8)
    else:
        background = np.array(
            [
                72 + (frame * 3 + seed) % 15,
                78 + (frame * 5 + seed) % 15,
                84 + (frame * 7 + seed) % 15,
            ],
            dtype=np.uint8,
        )
    image = np.empty((HEIGHT, WIDTH, 3), dtype=np.uint8)
    image[:, :] = background

    for index, region in enumerate(regions):
        base_color = np.asarray(_CLASS_COLORS_BGR[region["class"]], dtype=np.int16)
        color = tuple(int(value) for value in np.clip(base_color + color_jitter[index], 0, 255))
        if "box" in region:
            x, y, width, height = region["box"]
            cv2.rectangle(image, (x, y), (x + width, y + height), color, thickness=-1)
            label_origin = (x + 3, y + 16)
        else:
            points = np.asarray(region["polygon"], dtype=np.int32)
            cv2.fillPoly(image, [points], color)
            label_origin = (
                int(np.min(points[:, 0])) + 3,
                int(np.min(points[:, 1])) + 16,
            )
        cv2.putText(
            image,
            str(index + 1),
            label_origin,
            cv2.FONT_HERSHEY_SIMPLEX,
            0.35,
            (245, 245, 245),
            1,
            cv2.LINE_AA,
        )
    return image


def _plant_defects(
    model_output: list[dict[str, Any]],
    ground_truth: list[dict[str, Any]],
    seed: int,
) -> dict[str, Any]:
    defects: list[dict[str, Any]] = []
    for frame, region_id in ((12, "sample-r03"), (13, "sample-r04")):
        expected_region = _region_by_id(ground_truth[frame], region_id)
        model_region = _region_by_id(model_output[frame], region_id)
        expected_box = list(expected_region["box"])
        model_box = [expected_box[0] + 18, expected_box[1] + 8, *expected_box[2:]]
        model_region["box"] = model_box
        defects.append(
            {
                "type": "drift",
                "frame": frame,
                "region_id": region_id,
                "expected_box": expected_box,
                "model_box": model_box,
            }
        )

    wrong_class_region = _region_by_id(model_output[24], "sample-r05")
    expected_class = wrong_class_region["class"]
    wrong_class_region["class"] = "gallbladder"
    defects.append(
        {
            "type": "wrong_class",
            "frame": 24,
            "region_id": "sample-r05",
            "expected_class": expected_class,
            "model_class": "gallbladder",
        }
    )

    model_output[36]["regions"] = [
        region for region in model_output[36]["regions"] if region["id"] != "sample-r07"
    ]
    defects.append({"type": "missed_region", "frame": 36, "region_id": "sample-r07"})

    hallucinated_region = {
        "id": "hallucinated-f072",
        "class": "unknown",
        "kind": "region",
        "box": [500, 275, 72, 48],
        "conf": 0.41,
        "track_id": None,
    }
    model_output[72]["regions"].append(hallucinated_region)
    defects.append(
        {
            "type": "hallucinated_region",
            "frame": 72,
            "region_id": "hallucinated-f072",
            "model_region": deepcopy(hallucinated_region),
        }
    )

    first = _region_by_id(model_output[90], "sample-r01")
    second = _region_by_id(model_output[90], "sample-r02")
    expected_track_ids = {
        "sample-r01": first["track_id"],
        "sample-r02": second["track_id"],
    }
    first["track_id"], second["track_id"] = second["track_id"], first["track_id"]
    defects.append(
        {
            "type": "track_id_swap",
            "frame": 90,
            "region_ids": ["sample-r01", "sample-r02"],
            "expected_track_ids": expected_track_ids,
            "model_track_ids": {
                "sample-r01": first["track_id"],
                "sample-r02": second["track_id"],
            },
        }
    )

    return {
        "schema_version": 1,
        "dataset_id": DATASET_ID,
        "seed": seed,
        "types": [
            "drift",
            "wrong_class",
            "missed_region",
            "hallucinated_region",
            "track_id_swap",
        ],
        "similar_run": [SIMILAR_START, SIMILAR_END],
        "defects": defects,
    }


def _region_by_id(record: dict[str, Any], region_id: str) -> dict[str, Any]:
    return next(region for region in record["regions"] if region["id"] == region_id)


def _validate_outputs(manifest: dict[str, Any], records: list[dict[str, Any]]) -> None:
    manifest_errors = validate_instance(manifest, "dataset-manifest-v1.schema.json")
    manifest_errors.extend(validate_manifest_semantics(manifest))
    if manifest_errors:
        raise ValueError("invalid generated manifest: " + "; ".join(manifest_errors))

    for frame, record in enumerate(records):
        errors = validate_instance(record, "model_output_v1.schema.json")
        if errors:
            raise ValueError(
                f"invalid generated model output at frame {frame}: "
                + "; ".join(errors)
            )


def _write_json(path: Path, payload: Any) -> None:
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
