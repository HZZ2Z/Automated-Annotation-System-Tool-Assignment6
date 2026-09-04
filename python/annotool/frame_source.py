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
import numpy as np

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
    #检查输入和输出路径
    if output_dir.exists():
        raise FileExistsError(f"output directory already exists: {output_dir}")
    if not input_path.exists():
        raise FileNotFoundError(f"input video does not exist: {input_path}")
    if not input_path.is_file():
        raise ValueError(f"input video is not a file: {input_path}")
    if not output_dir.parent.is_dir():
        raise ValueError(f"output parent directory does not exist: {output_dir.parent}")
    #使用隐藏工作目录防止错误
    staging_dir = output_dir.parent / f".{output_dir.name}.tmp-{uuid4().hex}"
    try:
        probe = _probe_video(input_path) #用 FFprobe 读取视频信息
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
        width, height, similarity_scores = _validate_and_score_frames(frame_paths)
        manifest = _build_manifest(
            input_path, probe, frame_paths, width, height, similarity_scores
        )
        _validate_manifest(manifest)
        _write_manifest(staging_dir / "manifest.json", manifest)
        staging_dir.replace(output_dir)
        return manifest
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
    # 处理视频帧率
    nominal_fps = _parse_fps(stream.get("avg_frame_rate")) #程序优先读取：avg_frame_rate
    if nominal_fps is None:
        nominal_fps = _parse_fps(stream.get("r_frame_rate")) #如果读取不到，再使用：r_frame_rate
    if nominal_fps is None:
        raise ValueError("video has no valid nominal frame rate") #都读取不到 -报错

    frames = payload.get("frames")
    if not isinstance(frames, list) or not frames:
        raise ValueError("video has no readable frame timestamps")
    raw_timestamps: list[object] = []
    for index, frame in enumerate(frames):
        if not isinstance(frame, dict):
            raise ValueError(f"video frame {index} has no timestamp")
        raw_timestamps.append(frame.get("best_effort_timestamp_time"))

    missing_indices = [
        index for index, raw_timestamp in enumerate(raw_timestamps) if raw_timestamp is None
    ]
    if len(missing_indices) == len(raw_timestamps):
        timestamps = [index / nominal_fps for index in range(len(raw_timestamps))]
        return {
            "width": width,
            "height": height,
            "nominal_fps": nominal_fps,
            "timestamps": timestamps,
        }
    if missing_indices:
        raise ValueError(f"video frame {missing_indices[0]} has no timestamp")

    timestamps: list[float] = []
    for index, raw_timestamp in enumerate(raw_timestamps):
        try:
            timestamp = float(raw_timestamp) #将时间戳转换成浮点数
        except (TypeError, ValueError):
            raise ValueError(f"video frame {index} has invalid timestamp") from None
        if not math.isfinite(timestamp):
            raise ValueError(f"video frame {index} has invalid timestamp")
        if timestamps and timestamp < timestamps[-1]:
            raise ValueError("video frame timestamps are not monotonic")
        timestamps.append(timestamp)
    if timestamps[0] < 0:
        offset = -timestamps[0]
        timestamps = [timestamp + offset for timestamp in timestamps]
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
        "-map",
        "0:v:0",
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


def _validate_and_score_frames(frame_paths: list[Path]) -> tuple[int, int, list[float]]:
    """Check one decoded image at a time and retain only adjacent frames."""
    previous_image: np.ndarray | None = None
    decoded_shape: tuple[int, int, int] | None = None
    similarity_scores: list[float] = []
    for index, frame_path in enumerate(frame_paths):
        image = cv2.imread(str(frame_path), cv2.IMREAD_COLOR)
        if image is None:
            raise ValueError(f"decoded frame {index} is unreadable or has invalid dimensions")
        if decoded_shape is None:
            decoded_shape = image.shape
        elif image.shape != decoded_shape:
            raise ValueError(f"decoded frame {index} is unreadable or has invalid dimensions")
        if previous_image is not None:
            similarity_scores.append(normalized_mad(previous_image, image))
        previous_image = image
    if decoded_shape is None:
        raise ValueError("video decode produced no readable PNG frames")
    height, width, _ = decoded_shape
    return width, height, similarity_scores


def _build_manifest(
    input_path: Path,
    probe: dict[str, Any],
    frame_paths: list[Path],
    width: int,
    height: int,
    similarity_scores: list[float],
) -> dict[str, Any]:
    source_sha256 = _sha256_file(input_path)
    return {
        "schema_version": 1,
        "dataset_id": f"video-{source_sha256[:16]}",
        "source_name": input_path.name,
        "source_sha256": source_sha256,
        "width": width,
        "height": height,
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
        "similarity_scores": similarity_scores,
        "model_version": "none",
        "taxonomy_version": "none",
    }


def _sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


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
