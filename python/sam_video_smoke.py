#!/usr/bin/env python3
"""Run one bounded, no-download SAM 2 Video backend smoke.

The command reads only the explicitly named frame directory and key mask.  It
copies those inputs into a private temporary job, drives
``SamVideoBackend``, and publishes a JSON report plus bounded candidate PNGs
next to ``--json-out``.  Source frames and workspace labels are never written.
"""
from __future__ import annotations

import argparse
from copy import deepcopy
import hashlib
import importlib.metadata
import importlib.util
import json
import math
from numbers import Real
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import sys
import tempfile
import time
from typing import Any, Callable, Mapping

import cv2
import numpy as np

from annotation_data.sam_video_backend import SamVideoBackend
from annotation_data.sam_video_protocol import MAX_TARGETS, OBJECT_ID


SCHEMA = "project6-sam-video-smoke-v1"
MAX_INPUT_BYTES = 64 * 1024 * 1024
ROUNDTRIP_IOU = 0.99
_ENVIRONMENT_NAMES = (
    "PROJECT6_MODEL_PYTHON",
    "PROJECT6_SAM2_CONFIG",
    "PROJECT6_SAM2_CHECKPOINT",
    "PROJECT6_SAM2_DEVICE",
)
_PORTABLE_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+\-]{0,63}$")
_ABSOLUTE_PATH = re.compile(r"(?<![A-Za-z0-9])(?:/[^\s'\";,]+)+")
_WINDOWS_ABSOLUTE_PATH = re.compile(r"(?<![A-Za-z0-9])[A-Za-z]:\\\\[^\s'\";,]+")
_MAX_REASON_LENGTH = 160


class SmokeNotRun(RuntimeError):
    """A missing external prerequisite, never evidence of a failed model."""


class SmokeCancelled(RuntimeError):
    """The caller intentionally retired this smoke before publication."""


def _persisted_reason(value: object, fallback: str) -> str:
    """Keep report reasons bounded and free of host-specific absolute paths."""
    if not isinstance(value, str) or not value:
        return fallback
    if (
        len(value) > _MAX_REASON_LENGTH
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
        or _ABSOLUTE_PATH.search(value) is not None
        or _WINDOWS_ABSOLUTE_PATH.search(value) is not None
    ):
        return fallback
    return value


def resolve_sam2_version(
    sam2_module: object,
    distribution_lookup: Callable[[str], str] = importlib.metadata.version,
) -> str:
    """Return the installed portable SAM version or fail the evidence gate."""
    try:
        distribution_value: object = distribution_lookup("SAM-2")
    except importlib.metadata.PackageNotFoundError:
        distribution_value = ""
    module_value = getattr(sam2_module, "__version__", "")
    for value in (distribution_value, module_value):
        if (
            isinstance(value, str)
            and value != "unknown"
            and _PORTABLE_VERSION.fullmatch(value) is not None
        ):
            return value
    raise SmokeNotRun("SAM runtime did not report a valid installed model version")


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _read_regular(path: Path, label: str, *, suffix: str | None = None) -> bytes:
    if not path.is_absolute():
        raise ValueError(f"{label} must be an absolute path")
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ValueError(f"{label} is unavailable") from exc
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"{label} must be a regular non-symlink file")
    if suffix is not None and path.suffix.lower() != suffix:
        raise ValueError(f"{label} must be a {suffix} file")
    if metadata.st_size > MAX_INPUT_BYTES:
        raise ValueError(f"{label} exceeds the 64 MiB input limit")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ValueError(f"{label} could not be opened") from exc
    try:
        try:
            before = os.fstat(descriptor)
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(
                    descriptor, min(1024 * 1024, MAX_INPUT_BYTES + 1 - total)
                )
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > MAX_INPUT_BYTES:
                    raise ValueError(f"{label} exceeds the 64 MiB input limit")
            after = os.fstat(descriptor)
        except OSError as exc:
            raise ValueError(f"{label} could not be read") from exc
    finally:
        os.close(descriptor)
    try:
        final = path.lstat()
    except OSError as exc:
        raise ValueError(f"{label} changed while it was read") from exc
    identities = {
        (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns)
        for item in (before, after, final)
    }
    payload = b"".join(chunks)
    if len(identities) != 1 or len(payload) != after.st_size:
        raise ValueError(f"{label} changed while it was read")
    return payload


def _decode_png(payload: bytes, mode: int, label: str) -> np.ndarray:
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"{label} is not a PNG")
    image = cv2.imdecode(np.frombuffer(payload, np.uint8), mode)
    if image is None or image.size == 0:
        raise ValueError(f"{label} cannot be decoded")
    return image


def _write_exclusive(path: Path, payload: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())


def _write_json_exclusive(path: Path, value: dict[str, Any]) -> None:
    payload = (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            indent=2,
        )
        + "\n"
    ).encode("utf-8")
    _write_exclusive(path, payload)


def rasterize_start_mask(
    image_size: tuple[int, int], geometry: Mapping[str, object]
) -> np.ndarray:
    """Rasterize one Model Output V1 Box or Poly in original image space."""
    width, height = image_size
    if (
        isinstance(width, bool)
        or isinstance(height, bool)
        or not isinstance(width, int)
        or not isinstance(height, int)
        or width <= 0
        or height <= 0
    ):
        raise ValueError("image_size must contain positive integer width and height")
    if not isinstance(geometry, Mapping) or set(geometry) not in (
        {"box"},
        {"polygon"},
    ):
        raise ValueError("geometry must contain exactly one box or polygon")
    mask = np.zeros((height, width), np.uint8)
    if "box" in geometry:
        box = geometry["box"]
        if (
            not isinstance(box, (list, tuple))
            or len(box) != 4
            or any(
                isinstance(value, bool)
                or not isinstance(value, Real)
                or not math.isfinite(float(value))
                for value in box
            )
        ):
            raise ValueError("box must contain four finite numbers")
        x, y, box_width, box_height = (float(value) for value in box)
        if (
            x < 0
            or y < 0
            or box_width <= 0
            or box_height <= 0
            or x + box_width > width
            or y + box_height > height
        ):
            raise ValueError("box must be non-empty and stay inside the image")
        epsilon = 1e-9
        start_x = max(0, math.ceil(x - 0.5 - epsilon))
        end_x = min(width - 1, math.floor(x + box_width - 0.5 + epsilon))
        start_y = max(0, math.ceil(y - 0.5 - epsilon))
        end_y = min(height - 1, math.floor(y + box_height - 0.5 + epsilon))
        if start_x > end_x or start_y > end_y:
            raise ValueError("box covers no image pixel centers")
        mask[start_y:end_y + 1, start_x:end_x + 1] = 255
        return mask
    polygon = geometry["polygon"]
    if not isinstance(polygon, (list, tuple)) or not 3 <= len(polygon) <= 2048:
        raise ValueError("polygon must contain from 3 to 2048 points")
    points: list[list[float]] = []
    for point in polygon:
        if (
            not isinstance(point, (list, tuple))
            or len(point) != 2
            or any(
                isinstance(value, bool)
                or not isinstance(value, Real)
                or not math.isfinite(float(value))
                for value in point
            )
        ):
            raise ValueError("polygon points must be finite [x, y] pairs")
        x, y = (float(value) for value in point)
        if not 0.0 <= x <= width or not 0.0 <= y <= height:
            raise ValueError("polygon must stay inside the image")
        points.append([x, y])
    contour = np.asarray(points, np.float64)
    if abs(float(cv2.contourArea(contour.astype(np.float32)))) <= 1e-9:
        raise ValueError("polygon must be non-degenerate")
    _fill_polygon_pixel_centers(mask, contour)
    if not np.any(mask):
        raise ValueError("polygon covers no image pixel centers")
    return mask


def _fill_polygon_pixel_centers(mask: np.ndarray, contour: np.ndarray) -> None:
    """Fill pixel centers using an even/odd scanline, matching Godot's mask seam."""
    image_height, image_width = mask.shape
    epsilon = 1e-9
    minimum_y = float(np.min(contour[:, 1]))
    maximum_y = float(np.max(contour[:, 1]))
    first_row = max(0, math.ceil(minimum_y - 0.5 - epsilon))
    last_row = min(image_height - 1, math.floor(maximum_y - 0.5 + epsilon))
    for row in range(first_row, last_row + 1):
        center_y = row + 0.5
        intersections: list[float] = []
        boundary_spans: list[tuple[float, float]] = []
        for index in range(len(contour)):
            x1, y1 = (float(value) for value in contour[index])
            x2, y2 = (float(value) for value in contour[(index + 1) % len(contour)])
            if abs(y1 - y2) <= epsilon:
                if abs(center_y - y1) <= epsilon:
                    boundary_spans.append((min(x1, x2), max(x1, x2)))
                continue
            if (y1 <= center_y < y2) or (y2 <= center_y < y1):
                progress = (center_y - y1) / (y2 - y1)
                intersections.append(x1 + progress * (x2 - x1))
        intersections.sort()
        for index in range(0, len(intersections) - 1, 2):
            boundary_spans.append((intersections[index], intersections[index + 1]))
        for left, right in boundary_spans:
            start = max(0, math.ceil(left - 0.5 - epsilon))
            finish = min(image_width - 1, math.floor(right - 0.5 + epsilon))
            if start <= finish:
                mask[row, start:finish + 1] = 255


def ordered_frame_sources(frames_dir: str | Path, count: int) -> list[dict[str, Any]]:
    """Return the key plus ``count`` targets in numeric filename order."""
    if isinstance(count, bool) or not isinstance(count, int) or not 1 <= count <= MAX_TARGETS:
        raise ValueError(f"count must be an integer from 1 to {MAX_TARGETS}")
    directory = Path(frames_dir)
    if not directory.is_absolute():
        raise ValueError("frames directory must be an absolute path")
    try:
        metadata = directory.lstat()
    except OSError as exc:
        raise ValueError("frames directory is unavailable") from exc
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ValueError("frames directory must be a regular non-symlink directory")
    candidates: list[tuple[int, Path]] = []
    try:
        entries = list(directory.iterdir())
    except OSError as exc:
        raise ValueError("frames directory cannot be enumerated") from exc
    for path in entries:
        if path.suffix.lower() != ".png":
            continue
        try:
            frame_id = int(path.stem, 10)
        except ValueError as exc:
            raise ValueError(f"frame PNG must use a numeric stem: {path.name}") from exc
        if frame_id < 0:
            raise ValueError("frame IDs must be non-negative")
        candidates.append((frame_id, path))
    candidates.sort(key=lambda item: item[0])
    if len({frame_id for frame_id, _ in candidates}) != len(candidates):
        raise ValueError("frame IDs must be unique")
    required = count + 1
    if len(candidates) < required:
        raise ValueError(f"frames directory needs a key plus {count} targets")
    result: list[dict[str, Any]] = []
    image_size: tuple[int, int] | None = None
    for playback_index, (frame_id, path) in enumerate(candidates[:required]):
        payload = _read_regular(path, f"frame {frame_id}", suffix=".png")
        image = _decode_png(payload, cv2.IMREAD_COLOR, f"frame {frame_id}")
        height, width = image.shape[:2]
        if image_size is None:
            image_size = (width, height)
        elif image_size != (width, height):
            raise ValueError("all selected frames must have identical dimensions")
        result.append({
            "source": path,
            "name": path.name,
            "sha256": _sha256(payload),
            "payload": payload,
            "width": width,
            "height": height,
            "playback_index": playback_index,
            "frame_id": frame_id,
        })
    return result


def _runtime_environment(
    values: Mapping[str, str], *, fake: bool
) -> dict[str, Any]:
    missing = [name for name in _ENVIRONMENT_NAMES if not values.get(name)]
    if missing:
        raise SmokeNotRun("missing required environment: " + ", ".join(missing))
    python = Path(values["PROJECT6_MODEL_PYTHON"])
    if not python.is_absolute() or not python.is_file() or not os.access(python, os.X_OK):
        raise SmokeNotRun("PROJECT6_MODEL_PYTHON is not an executable file")
    config = Path(values["PROJECT6_SAM2_CONFIG"])
    checkpoint = Path(values["PROJECT6_SAM2_CHECKPOINT"])
    try:
        config_payload = _read_regular(config, "PROJECT6_SAM2_CONFIG")
        checkpoint_payload = _read_regular(checkpoint, "PROJECT6_SAM2_CHECKPOINT")
    except ValueError as exc:
        raise SmokeNotRun(str(exc)) from exc
    device = values["PROJECT6_SAM2_DEVICE"]
    if device not in {"auto", "cpu", "cuda"}:
        raise SmokeNotRun("PROJECT6_SAM2_DEVICE must be auto, cpu or cuda")
    result: dict[str, Any] = {
        "python_version": platform.python_version(),
        "torch_version": "injected-fake" if fake else None,
        "sam2_version": "injected-fake" if fake else None,
        "cuda_available": False,
        "requested_device": device,
        "actual_device": None,
        "config_sha256": _sha256(config_payload),
        "checkpoint_sha256": _sha256(checkpoint_payload),
    }
    if fake:
        return result
    try:
        same_interpreter = os.path.samefile(python, Path(sys.executable))
    except OSError:
        same_interpreter = False
    if not same_interpreter:
        raise SmokeNotRun(
            "current interpreter does not match PROJECT6_MODEL_PYTHON; "
            "launch this smoke with the configured external interpreter"
        )
    if importlib.util.find_spec("torch") is None or importlib.util.find_spec("sam2") is None:
        raise SmokeNotRun("configured external runtime does not provide torch and sam2")
    import sam2
    import torch

    result["torch_version"] = str(torch.__version__)
    result["sam2_version"] = resolve_sam2_version(sam2)
    result["cuda_available"] = bool(torch.cuda.is_available())
    if device == "cuda" and not result["cuda_available"]:
        raise SmokeNotRun("CUDA was explicitly requested but is unavailable")
    return result


def _topology(
    payload: bytes, descriptor: Mapping[str, Any], image_size: tuple[int, int]
) -> dict[str, Any]:
    crop = _decode_png(payload, cv2.IMREAD_GRAYSCALE, "candidate")
    if not set(np.unique(crop).tolist()).issubset({0, 255}):
        return {"status": "FAIL", "reason": "non_binary"}
    roi = descriptor.get("roi")
    if (
        not isinstance(roi, list)
        or len(roi) != 4
        or any(isinstance(value, bool) or not isinstance(value, int) for value in roi)
    ):
        return {"status": "FAIL", "reason": "invalid_roi"}
    x, y, width, height = roi
    image_width, image_height = image_size
    if (
        x < 0
        or y < 0
        or width <= 0
        or height <= 0
        or x + width > image_width
        or y + height > image_height
        or crop.shape != (height, width)
    ):
        return {"status": "FAIL", "reason": "invalid_roi"}
    full = np.zeros((image_height, image_width), np.uint8)
    full[y:y + height, x:x + width] = crop
    foreground = int(np.count_nonzero(full))
    if foreground == 0:
        return {"status": "FAIL", "reason": "empty"}
    if foreground == full.size:
        return {"status": "FAIL", "reason": "full_image"}
    component_count, _ = cv2.connectedComponents((full > 0).astype(np.uint8), 8)
    if component_count != 2:
        return {
            "status": "FAIL",
            "reason": "multiple_components",
            "component_count": component_count - 1,
        }
    contours, hierarchy = cv2.findContours(
        (full > 0).astype(np.uint8), cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE
    )
    if len(contours) != 1 or hierarchy is None or int(hierarchy[0][0][2]) != -1:
        return {"status": "FAIL", "reason": "hole"}
    contour = contours[0].reshape(-1, 2)
    vertex_count = int(len(contour))
    if vertex_count < 3 or vertex_count > 2048 or cv2.contourArea(contour) <= 0.0:
        return {"status": "FAIL", "reason": "degenerate", "vertex_count": vertex_count}
    if not _is_simple_ring(contour):
        return {
            "status": "FAIL",
            "reason": "non_simple_polygon",
            "vertex_count": vertex_count,
        }
    roundtrip = np.zeros_like(full)
    cv2.fillPoly(roundtrip, [contour.astype(np.int32)], 255)
    intersection = int(np.count_nonzero((roundtrip > 0) & (full > 0)))
    union = int(np.count_nonzero((roundtrip > 0) | (full > 0)))
    iou = float(intersection / union) if union else 0.0
    if iou < ROUNDTRIP_IOU:
        return {
            "status": "FAIL",
            "reason": "non_lossless_polygon",
            "vertex_count": vertex_count,
            "roundtrip_iou": round(iou, 6),
        }
    return {
        "status": "PASS",
        "reason": "",
        "component_count": 1,
        "has_holes": False,
        "vertex_count": vertex_count,
        "roundtrip_iou": round(iou, 6),
        "foreground_pixels": foreground,
    }


def _is_simple_ring(contour: np.ndarray) -> bool:
    """Match the production V1 gate: distinct vertices and no edge contact."""
    if len(np.unique(contour, axis=0)) != len(contour):
        return False

    def cross(first: np.ndarray, second: np.ndarray, third: np.ndarray) -> int:
        left = second.astype(np.int64) - first.astype(np.int64)
        right = third.astype(np.int64) - first.astype(np.int64)
        return int(left[0] * right[1] - left[1] * right[0])

    def intersects(
        first_start: np.ndarray,
        first_end: np.ndarray,
        second_start: np.ndarray,
        second_end: np.ndarray,
    ) -> bool:
        if np.any(
            np.maximum(
                np.minimum(first_start, first_end),
                np.minimum(second_start, second_end),
            )
            > np.minimum(
                np.maximum(first_start, first_end),
                np.maximum(second_start, second_end),
            )
        ):
            return False
        return (
            cross(first_start, first_end, second_start)
            * cross(first_start, first_end, second_end)
            <= 0
            and cross(second_start, second_end, first_start)
            * cross(second_start, second_end, first_end)
            <= 0
        )

    count = len(contour)
    for first_edge in range(count):
        first_end = (first_edge + 1) % count
        for second_edge in range(first_edge + 1, count):
            second_end = (second_edge + 1) % count
            if first_edge == second_end or first_end == second_edge:
                continue
            if intersects(
                contour[first_edge],
                contour[first_end],
                contour[second_edge],
                contour[second_end],
            ):
                return False
    return True


def _empty_report() -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "status": "FAIL",
        "reason": "",
        "environment": None,
        "input": {"count": None, "key_mask_sha256": None, "frames": []},
        "timings_ms": {"load": None, "open": None, "propagate": None},
        "candidates": [],
        "stop": None,
        "artifacts": "",
        "cuda": {
            "peak_vram_bytes": None,
            "per_frame_propagate_ms": [],
            "inflight_cancel_latency_ms": None,
        },
    }


def run_smoke(
    frames_dir: str | Path,
    mask_path: str | Path,
    count: int,
    json_out: str | Path,
    *,
    predictor_factory: Callable[[str, str, str], Any] | None = None,
    environ: Mapping[str, str] | None = None,
    cancel_requested: Callable[[], bool] | None = None,
    clock: Callable[[], float] = time.perf_counter,
) -> dict[str, Any]:
    """Run the backend once and atomically publish a bounded evidence report."""
    output = Path(json_out)
    raw_frames = Path(frames_dir)
    if raw_frames.is_absolute():
        try:
            frames_root = raw_frames.resolve(strict=True)
            output.resolve(strict=False).relative_to(frames_root)
        except (OSError, ValueError):
            pass
        else:
            raise ValueError(
                "--json-out must stay outside the source frame directory"
            )
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() or output.is_symlink():
        raise ValueError("--json-out must not already exist")
    artifacts_name = output.stem + ".artifacts"
    artifacts = output.parent / artifacts_name
    if artifacts.exists() or artifacts.is_symlink():
        raise ValueError("smoke artifact directory already exists")
    report = _empty_report()
    report["artifacts"] = artifacts_name
    values = dict(os.environ if environ is None else environ)
    artifact_staging: Path | None = None
    try:
        environment = _runtime_environment(
            values, fake=predictor_factory is not None
        )
        report["environment"] = environment
        frames = ordered_frame_sources(frames_dir, count)
        key_payload = _read_regular(Path(mask_path), "key mask", suffix=".png")
        key_mask = _decode_png(key_payload, cv2.IMREAD_GRAYSCALE, "key mask")
        key_size = (frames[0]["width"], frames[0]["height"])
        if key_mask.shape != (key_size[1], key_size[0]):
            raise ValueError("key mask dimensions must match the selected frames")
        values_in_mask = set(np.unique(key_mask).tolist())
        if not values_in_mask.issubset({0, 255}):
            raise ValueError("key mask must contain only binary 0/255 pixels")
        foreground = int(np.count_nonzero(key_mask))
        if foreground == 0 or foreground == key_mask.size:
            raise ValueError("key mask must be non-empty and not cover the full image")
        report["input"] = {
            "count": count,
            "key_mask_sha256": _sha256(key_payload),
            "frames": [
                {
                    key: item[key]
                    for key in (
                        "name",
                        "sha256",
                        "width",
                        "height",
                        "playback_index",
                        "frame_id",
                    )
                }
                for item in frames
            ],
        }
        with tempfile.TemporaryDirectory(
            prefix=".sam-video-smoke-job-", dir=output.parent
        ) as raw_job:
            job = Path(raw_job)
            frozen = job / "frozen"
            frozen.mkdir(mode=0o700)
            backend_frames: list[dict[str, Any]] = []
            for index, item in enumerate(frames):
                relative = f"frozen/frame-{index:06d}.png"
                _write_exclusive(job / relative, item["payload"])
                backend_frames.append({
                    "path": relative,
                    "sha256": item["sha256"],
                    "width": item["width"],
                    "height": item["height"],
                    "playback_index": item["playback_index"],
                    "frame_id": item["frame_id"],
                })
            key_relative = "frozen/key-mask.png"
            _write_exclusive(job / key_relative, key_payload)
            backend = SamVideoBackend(
                job,
                config_path=values["PROJECT6_SAM2_CONFIG"],
                checkpoint_path=values["PROJECT6_SAM2_CHECKPOINT"],
                device=values["PROJECT6_SAM2_DEVICE"],
                predictor_factory=predictor_factory,
            )
            try:
                started = clock()
                hello = backend.hello()
                report["timings_ms"]["load"] = (
                    0.0
                    if predictor_factory is not None
                    else round((clock() - started) * 1000.0, 3)
                )
                if hello.get("checkpoint_sha256") != environment["checkpoint_sha256"]:
                    raise ValueError("backend checkpoint digest did not match preflight")
                environment["actual_device"] = hello.get("device")
                started = clock()
                backend.open_batch(backend_frames)
                report["timings_ms"]["open"] = (
                    0.0
                    if predictor_factory is not None
                    else round((clock() - started) * 1000.0, 3)
                )
                if cancel_requested is not None and cancel_requested():
                    backend.cancel("smoke-cancel")
                    raise SmokeCancelled("cancelled")
                backend.add_mask(
                    {
                        "path": key_relative,
                        "sha256": _sha256(key_payload),
                        "roi": [0, 0, key_size[0], key_size[1]],
                    },
                    OBJECT_ID,
                )
                if cancel_requested is not None and cancel_requested():
                    backend.cancel("smoke-cancel")
                    raise SmokeCancelled("cancelled")
                started = clock()
                propagated = backend.propagate(count, OBJECT_ID)
                report["timings_ms"]["propagate"] = (
                    0.0
                    if predictor_factory is not None
                    else round((clock() - started) * 1000.0, 3)
                )
                raw_artifacts = tempfile.mkdtemp(
                    prefix=".sam-video-smoke-artifacts-", dir=output.parent
                )
                artifact_staging = Path(raw_artifacts)
                for descriptor in propagated["masks"]:
                    local_index = descriptor["local_index"]
                    source = job / descriptor["path"]
                    payload = _read_regular(source, "backend candidate", suffix=".png")
                    if _sha256(payload) != descriptor["sha256"]:
                        raise ValueError("backend candidate digest changed")
                    topology = _topology(payload, descriptor, key_size)
                    if topology["status"] != "PASS":
                        report["stop"] = {
                            "kind": "candidate_topology",
                            "frame_id": descriptor["frame_id"],
                            "playback_index": descriptor["playback_index"],
                            "topology": topology,
                        }
                        break
                    name = f"frame-{local_index:06d}.png"
                    _write_exclusive(artifact_staging / name, payload)
                    accepted = {
                        key: deepcopy(descriptor[key])
                        for key in (
                            "local_index",
                            "playback_index",
                            "frame_id",
                            "object_id",
                            "roi",
                            "score",
                            "sha256",
                        )
                    }
                    accepted["path"] = name
                    accepted["topology"] = topology
                    report["candidates"].append(accepted)
                if environment["actual_device"] == "cuda" and predictor_factory is None:
                    import torch

                    report["cuda"]["peak_vram_bytes"] = int(
                        torch.cuda.max_memory_allocated()
                    )
            finally:
                backend.shutdown()
        if artifact_staging is None:
            raise RuntimeError("smoke did not create an artifact staging directory")
        os.replace(artifact_staging, artifacts)
        artifact_staging = None
        report["status"] = "PASS"
    except SmokeCancelled:
        report["status"] = "NOT RUN"
        report["reason"] = "cancelled"
        report["candidates"] = []
        report["stop"] = None
    except SmokeNotRun as exc:
        report["status"] = "NOT RUN"
        report["reason"] = _persisted_reason(str(exc), "runtime prerequisite unavailable")
    except OSError:
        report["status"] = "FAIL"
        report["reason"] = "smoke input or output operation failed"
    except ValueError as exc:
        report["status"] = "FAIL"
        report["reason"] = _persisted_reason(str(exc), "smoke validation failed")
    except Exception:
        report["status"] = "FAIL"
        report["reason"] = "smoke execution failed"
    finally:
        if artifact_staging is not None:
            shutil.rmtree(artifact_staging, ignore_errors=True)
        _write_json_exclusive(output, report)
    return deepcopy(report)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frames", required=True, type=Path)
    parser.add_argument("--mask", required=True, type=Path)
    parser.add_argument("--count", required=True, type=int)
    parser.add_argument("--json-out", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        report = run_smoke(args.frames, args.mask, args.count, args.json_out)
    except (OSError, ValueError) as exc:
        print(f"SAM Video smoke FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"SAM Video smoke {report['status']}: {args.json_out}")
    return 1 if report["status"] == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
