"""Build a small, auditable Endoscapes workspace without modifying the dataset."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

import cv2
import numpy as np

from .contracts import validate_instance
from .polygon_geometry import mask_iou, mask_to_polygon, polygon_to_mask


FRAME_STEP = 25
MIN_FRAMES = 5
MAX_FRAMES = 30
BOUNDARY_INSET_PIXELS = 2
MODEL_VERSION = "model_output_v1"
TAXONOMY_VERSION = "endoscapes2023-insseg-v1"
CATEGORIES = {
    1: ("cystic_plate", "anatomy"),
    2: ("calot_triangle", "anatomy"),
    3: ("cystic_artery", "anatomy"),
    4: ("cystic_duct", "anatomy"),
    5: ("gallbladder", "anatomy"),
    6: ("tool", "tool"),
}


@dataclass(frozen=True)
class BuildRequest:
    dataset_root: Path
    output: Path
    video_id: int
    start_frame: int
    end_frame: int
    key_frame: int
    instance_index: int
    copy_images: bool = False


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )


def _discover_image(root: Path, video_id: int, frame: int) -> Path:
    stem = f"{video_id}_{frame}"
    matches = sorted(
        path for path in (root / "train").rglob(f"{stem}.*")
        if path.is_file() and path.suffix.lower() in {".jpg", ".jpeg", ".png"}
    )
    if not matches:
        raise ValueError(f"missing frame {stem} in dataset train directory")
    if len(matches) != 1:
        raise ValueError(f"duplicate frame {stem}: expected one image, found {len(matches)}")
    return matches[0]


def _frame_numbers(request: BuildRequest) -> list[int]:
    for name in ("video_id", "start_frame", "end_frame", "key_frame", "instance_index"):
        value = getattr(request, name)
        if type(value) is not int or value < 0:
            raise ValueError(f"{name} must be a nonnegative integer")
    if request.end_frame < request.start_frame:
        raise ValueError("end frame must not precede start frame")
    if (request.end_frame - request.start_frame) % FRAME_STEP:
        raise ValueError("start/end frame difference must be in multiples of 25")
    frames = list(range(request.start_frame, request.end_frame + 1, FRAME_STEP))
    if not MIN_FRAMES <= len(frames) <= MAX_FRAMES:
        raise ValueError("fixture must contain 5 to 30 frames")
    if request.key_frame not in frames:
        raise ValueError("key frame must belong to the requested step-25 range")
    return frames


def _load_seed(request: BuildRequest, size: tuple[int, int]) -> tuple[list[list[float]], dict]:
    stem = f"{request.video_id}_{request.key_frame}"
    mask_path = request.dataset_root / "insseg" / f"{stem}.npy"
    labels_path = request.dataset_root / "insseg" / f"{stem}.csv"
    if not mask_path.is_file() or not labels_path.is_file():
        raise ValueError(f"key frame mask/CSV pair is missing for {stem}")
    try:
        masks = np.load(mask_path, allow_pickle=False)
        labels = np.loadtxt(labels_path, delimiter=",", ndmin=1)
    except (OSError, ValueError) as error:
        raise ValueError(f"could not read key frame mask/CSV: {error}") from error
    if masks.ndim != 3 or masks.shape[1:] != (size[1], size[0]):
        raise ValueError("key frame mask dimensions do not match the source images")
    if not np.issubdtype(masks.dtype, np.number) or not np.isfinite(masks).all():
        raise ValueError("key frame masks must contain finite numeric values")
    if not np.all((masks == 0) | (masks == 1)):
        raise ValueError("key frame masks must be binary 0/1 arrays")
    if labels.ndim != 1 or len(labels) != len(masks):
        raise ValueError("mask/CSV count mismatch for key frame instances")
    if request.instance_index >= len(masks):
        raise ValueError("instance index is outside the key frame mask array")
    label = float(labels[request.instance_index])
    if not label.is_integer() or int(label) not in CATEGORIES:
        raise ValueError("selected instance category is not in the Endoscapes taxonomy")

    original = masks[request.instance_index].astype(np.uint8, copy=True)
    seed = original.copy()
    touches = bool(
        seed[0].any() or seed[-1].any() or seed[:, 0].any() or seed[:, -1].any()
    )
    inset = BOUNDARY_INSET_PIXELS if touches else 0
    if touches:
        seed[:inset, :] = 0
        seed[-inset:, :] = 0
        seed[:, :inset] = 0
        seed[:, -inset:] = 0
    retained_iou = mask_iou(original * 255, seed * 255)
    try:
        polygon = mask_to_polygon(seed * 255, size)
    except ValueError as error:
        raise ValueError(f"selected instance cannot form one V1 polygon: {error}") from error
    raster = polygon_to_mask(np.asarray(polygon, np.float64), size, seed.shape)
    polygon_iou = mask_iou(raster, seed * 255)
    category_id = int(label)
    category, kind = CATEGORIES[category_id]
    return polygon, {
        "source_mask_file": f"insseg/{stem}.npy",
        "source_mask_sha256": _sha256(mask_path),
        "source_labels_file": f"insseg/{stem}.csv",
        "source_labels_sha256": _sha256(labels_path),
        "instance_index": request.instance_index,
        "category_id": category_id,
        "category": category,
        "kind": kind,
        "source_pixel_count": int(np.count_nonzero(original)),
        "seed_pixel_count": int(np.count_nonzero(seed)),
        "boundary_inset_pixels": inset,
        "lossless": not touches,
        "retained_iou": retained_iou,
        "polygon_raster_iou": polygon_iou,
        "warning": (
            "Source mask touched the image boundary; a two-pixel outer border was removed "
            "to create a bounded V1 seed. This is a declared lossy fixture transform."
            if touches else ""
        ),
    }


def _validate_outputs(manifest: dict, records: list[dict]) -> None:
    errors = validate_instance(manifest, "dataset-manifest-v1.schema.json")
    if errors:
        raise ValueError("generated manifest is invalid: " + errors[0])
    for index, record in enumerate(records):
        errors = validate_instance(record, "model_output_v1.schema.json")
        if errors:
            raise ValueError(f"generated model record {index} is invalid: {errors[0]}")


def build_fixture(request: BuildRequest) -> dict:
    """Create one fixture by sibling staging + rename; all dataset inputs stay read-only."""
    dataset_root = request.dataset_root.resolve()
    output = request.output.resolve()
    request = BuildRequest(dataset_root, output, request.video_id, request.start_frame,
                           request.end_frame, request.key_frame, request.instance_index,
                           request.copy_images)
    if not dataset_root.is_dir():
        raise ValueError("dataset root does not exist")
    if output.exists() or output.is_symlink():
        raise ValueError("output already exists; choose a new destination")
    if output == dataset_root or dataset_root in output.parents:
        raise ValueError("output must be outside the source dataset")
    frames = _frame_numbers(request)
    sources = [_discover_image(dataset_root, request.video_id, frame) for frame in frames]
    decoded = [cv2.imread(str(path), cv2.IMREAD_COLOR) for path in sources]
    if any(image is None for image in decoded):
        raise ValueError("one or more source frames could not be decoded")
    height, width = decoded[0].shape[:2]
    if any(image.shape[:2] != (height, width) for image in decoded):
        raise ValueError("all source frames must have identical dimensions")
    polygon, seed_info = _load_seed(request, (width, height))

    frame_info = [
        {
            "playback_index": index,
            "original_frame_id": frame,
            "source_file": f"train/{path.name}",
            "sha256": _sha256(path),
        }
        for index, (frame, path) in enumerate(zip(frames, sources))
    ]
    source_hasher = hashlib.sha256()
    for info in frame_info:
        source_hasher.update(f"{info['original_frame_id']}\0{info['sha256']}\n".encode())
    dataset_id = f"endoscapes-{request.video_id}-{request.start_frame}-{request.end_frame}"
    source_name = f"endoscapes-video-{request.video_id}"
    manifest = {
        "schema_version": 1,
        "dataset_id": dataset_id,
        "source_name": source_name,
        "source_sha256": source_hasher.hexdigest(),
        "width": width,
        "height": height,
        "frame_count": len(frames),
        "nominal_fps": 1.0,
        "frames": [
            {"frame": index, "time_s": float(index),
             "image_path": f"frames/frame_{index:06d}{path.suffix.lower()}"}
            for index, path in enumerate(sources)
        ],
        "model_version": MODEL_VERSION,
        "taxonomy_version": TAXONOMY_VERSION,
    }
    key_index = frames.index(request.key_frame)
    region = {
        "id": f"endoscapes-{request.video_id}-{request.key_frame}-instance-{request.instance_index}",
        "class": seed_info["category"],
        "kind": seed_info["kind"],
        "polygon": polygon,
    }
    records = [
        {
            "schema_version": 1,
            "source": source_name,
            "frame": index,
            "time_s": float(index),
            "regions": [region] if index == key_index else [],
        }
        for index in range(len(frames))
    ]
    _validate_outputs(manifest, records)
    provenance = {
        "schema_version": 1,
        "fixture_type": "endoscapes-poly-acceptance",
        "dataset_name": "Endoscapes2023",
        "dataset_id": dataset_id,
        "frame_step": FRAME_STEP,
        "copy_mode": "copy" if request.copy_images else "symlink",
        "frames": frame_info,
        "keyframe_seed": {"original_frame_id": request.key_frame,
                          "playback_index": key_index, **seed_info},
        "evidence_limit": (
            "Only the keyframe has an instance mask. Target-frame propagation is qualitative "
            "review evidence and is not dense-IoU ground truth."
        ),
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.staging-", dir=output.parent))
    try:
        (staging / "frames").mkdir()
        for source, entry in zip(sources, manifest["frames"]):
            destination = staging / entry["image_path"]
            if request.copy_images:
                shutil.copyfile(source, destination)
            else:
                destination.symlink_to(source)
        _write_json(staging / "manifest.json", manifest)
        with (staging / f"{MODEL_VERSION}.jsonl").open("w", encoding="utf-8") as stream:
            for record in records:
                stream.write(json.dumps(record, ensure_ascii=False, allow_nan=False,
                                        sort_keys=True, separators=(",", ":")) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        _write_json(staging / "provenance.json", provenance)
        staging.replace(output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return {
        "output": str(output),
        "frame_count": len(frames),
        "key_playback_index": key_index,
        "key_original_frame_id": request.key_frame,
        "category_id": seed_info["category_id"],
        "category": seed_info["category"],
        "boundary_inset_pixels": seed_info["boundary_inset_pixels"],
        "retained_iou": seed_info["retained_iou"],
    }
