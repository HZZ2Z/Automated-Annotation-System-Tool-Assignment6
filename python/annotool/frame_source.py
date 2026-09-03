"""Normalize an FFmpeg-supported video into the dataset frame-source format."""

import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
from typing import Any
from uuid import uuid4

import cv2

from annotool.contracts import validate_instance, validate_manifest_semantics
from annotool.similarity import normalized_mad


_FRAME_NAME = re.compile(r"frame_(\d{6})\.png$")


def decode_video(input_path: Path, output_dir: Path) -> dict[str, Any]:
    """Decode ``input_path`` into ``output_dir`` and return its normalized metadata.

    The published directory is created only after probing, extraction, image checks,
    and manifest validation have all succeeded.
    """
    input_path = Path(input_path)
    output_dir = Path(output_dir)
    if output_dir.exists():
        raise FileExistsError(f"output directory already exists: {output_dir}")
    if not input_path.exists():
        raise FileNotFoundError(f"input video does not exist: {input_path}")
    if not input_path.is_file():
        raise ValueError(f"input video is not a file: {input_path}")
    if not output_dir.parent.is_dir():
        raise ValueError(f"output parent directory does not exist: {output_dir.parent}")

    staging_dir = output_dir.parent / f".{output_dir.name}.tmp-{uuid4().hex}"
    try:
        probe = _probe_video(input_path)
        staging_dir.mkdir()
        frames_dir = staging_dir / "frames"
        frames_dir.mkdir()
        _extract_frames(input_path, frames_dir)
        frame_paths = _normalize_frame_names(frames_dir)
        if len(probe["timestamps"]) != len(frame_paths):
            raise ValueError(
                "video timestamp count does not match extracted frame count "
                f"({len(probe['timestamps'])} != {len(frame_paths)})"
            )
        images = _read_and_validate_images(frame_paths, probe["width"], probe["height"])
        manifest = _build_manifest(input_path, probe, frame_paths)
        _validate_manifest(manifest)
        similarity_scores = [
            normalized_mad(images[index], images[index + 1])
            for index in range(len(images) - 1)
        ]
        _write_manifest(staging_dir / "manifest.json", manifest)
        staging_dir.replace(output_dir)
        return {**manifest, "similarity_scores": similarity_scores}
    except Exception:
        if staging_dir.exists():
            shutil.rmtree(staging_dir)
        raise


def _probe_video(input_path: Path) -> dict[str, Any]:
    payload = _run_json(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_streams",
            "-show_frames",
            "-show_entries",
            "stream=width,height,avg_frame_rate,r_frame_rate:frame=best_effort_timestamp_time",
            "-of",
            "json",
            str(input_path),
        ],
        "probe",
    )
    streams = payload.get("streams")
    if not isinstance(streams, list) or len(streams) != 1 or not isinstance(streams[0], dict):
        raise ValueError("video has no readable video stream")
    stream = streams[0]
    width, height = stream.get("width"), stream.get("height")
    if type(width) is not int or type(height) is not int or width <= 0 or height <= 0:
        raise ValueError("video has invalid dimensions")
    nominal_fps = _parse_fps(stream.get("avg_frame_rate"))
    if nominal_fps is None:
        nominal_fps = _parse_fps(stream.get("r_frame_rate"))
    if nominal_fps is None:
        raise ValueError("video has no valid nominal frame rate")

    frames = payload.get("frames")
    if not isinstance(frames, list) or not frames:
        raise ValueError("video has no readable frame timestamps")
    timestamps: list[float] = []
    for index, frame in enumerate(frames):
        if not isinstance(frame, dict):
            raise ValueError(f"video frame {index} has no timestamp")
        raw_timestamp = frame.get("best_effort_timestamp_time")
        try:
            timestamp = float(raw_timestamp)
        except (TypeError, ValueError):
            raise ValueError(f"video frame {index} has no timestamp") from None
        if not math.isfinite(timestamp) or timestamp < 0:
            raise ValueError(f"video frame {index} has invalid timestamp")
        if timestamps and timestamp < timestamps[-1]:
            raise ValueError("video frame timestamps are not monotonic")
        timestamps.append(timestamp)
    return {
        "width": width,
        "height": height,
        "nominal_fps": nominal_fps,
        "timestamps": timestamps,
    }


def _run_json(command: list[str], action: str) -> dict[str, Any]:
    try:
        completed = subprocess.run(command, check=False, capture_output=True, text=True)
    except OSError as error:
        raise ValueError(f"could not run {command[0]} for video {action}: {error}") from None
    if completed.returncode != 0:
        detail = completed.stderr.strip() or "unknown error"
        raise ValueError(f"video {action} failed: {detail}")
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        raise ValueError(f"video {action} returned invalid metadata") from None
    if not isinstance(payload, dict):
        raise ValueError(f"video {action} returned invalid metadata")
    return payload


def _parse_fps(value: object) -> float | None:
    if not isinstance(value, str) or "/" not in value:
        return None
    numerator, denominator = value.split("/", 1)
    try:
        fps = float(numerator) / float(denominator)
    except (ValueError, ZeroDivisionError):
        return None
    return fps if math.isfinite(fps) and fps > 0 else None


def _extract_frames(input_path: Path, frames_dir: Path) -> None:
    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(input_path),
        "-vsync",
        "0",
        str(frames_dir / "frame_%06d.png"),
    ]
    try:
        completed = subprocess.run(command, check=False, capture_output=True, text=True)
    except OSError as error:
        raise ValueError(f"could not run ffmpeg: {error}") from None
    if completed.returncode != 0:
        detail = completed.stderr.strip() or "unknown error"
        raise ValueError(f"video decode failed: {detail}")


def _normalize_frame_names(frames_dir: Path) -> list[Path]:
    source_paths = sorted(frames_dir.glob("frame_*.png"))
    if not source_paths:
        raise ValueError("video decode produced no PNG frames")
    source_indices: list[int] = []
    for path in source_paths:
        match = _FRAME_NAME.fullmatch(path.name)
        if match is None:
            raise ValueError(f"video decode produced an unexpected frame name: {path.name}")
        source_indices.append(int(match.group(1)))
    expected_indices = list(range(1, len(source_paths) + 1))
    if source_indices != expected_indices:
        raise ValueError("video decode produced non-contiguous frame indices")

    temporary_paths: list[Path] = []
    for index, source_path in enumerate(source_paths):
        temporary_path = frames_dir / f".renaming_{index:06d}.png"
        source_path.replace(temporary_path)
        temporary_paths.append(temporary_path)
    normalized_paths: list[Path] = []
    for index, temporary_path in enumerate(temporary_paths):
        normalized_path = frames_dir / f"frame_{index:06d}.png"
        temporary_path.replace(normalized_path)
        normalized_paths.append(normalized_path)
    return normalized_paths


def _read_and_validate_images(frame_paths: list[Path], width: int, height: int) -> list[Any]:
    images: list[Any] = []
    for index, frame_path in enumerate(frame_paths):
        image = cv2.imread(str(frame_path), cv2.IMREAD_COLOR)
        if image is None or image.shape != (height, width, 3):
            raise ValueError(f"decoded frame {index} is unreadable or has invalid dimensions")
        images.append(image)
    return images


def _build_manifest(
    input_path: Path, probe: dict[str, Any], frame_paths: list[Path]
) -> dict[str, Any]:
    source_sha256 = hashlib.sha256(input_path.read_bytes()).hexdigest()
    return {
        "schema_version": 1,
        "dataset_id": f"video-{source_sha256[:16]}",
        "source_name": input_path.name,
        "source_sha256": source_sha256,
        "width": probe["width"],
        "height": probe["height"],
        "frame_count": len(frame_paths),
        "nominal_fps": probe["nominal_fps"],
        "frames": [
            {
                "frame": index,
                "time_s": probe["timestamps"][index],
                "image_path": f"frames/{frame_path.name}",
            }
            for index, frame_path in enumerate(frame_paths)
        ],
        "model_version": "none",
        "taxonomy_version": "none",
    }


def _validate_manifest(manifest: dict[str, Any]) -> None:
    errors = validate_instance(manifest, "dataset-manifest-v1.schema.json")
    errors.extend(validate_manifest_semantics(manifest))
    if errors:
        raise ValueError("generated manifest is invalid: " + "; ".join(errors))


def _write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
