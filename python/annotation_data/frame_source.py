"""Normalize an FFmpeg-supported video into the dataset frame-source format."""

import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import tempfile
import time
from typing import Any, Callable
from uuid import uuid4

import cv2
import numpy as np

from annotation_data.contracts import validate_instance, validate_manifest_semantics
from annotation_data.similarity import normalized_mad


_FRAME_NAME = re.compile(r"frame_(\d{6})\.png$")
_PROJECT_ROOT = Path(__file__).resolve().parents[2]
_PROJECT_MEDIA_BIN = _PROJECT_ROOT / ".tools" / "ffmpeg" / "bin"

ProgressCallback = Callable[[dict[str, Any]], None]
CancelCheck = Callable[[], bool]


class VideoImportCancelled(RuntimeError):
    """Raised after a cooperative video-import cancellation request."""


def _media_tool(name: str) -> str:
    project_tool = _PROJECT_MEDIA_BIN / name
    if project_tool.is_file() and os.access(project_tool, os.X_OK):
        return str(project_tool)
    resolved = shutil.which(name)
    if resolved is not None:
        return resolved
    raise FileNotFoundError(
        f"required media tool '{name}' was not found; expected an executable at "
        f"{project_tool} or on PATH"
    )


def decode_video(
    input_path: Path,
    output_dir: Path,
    *,
    progress_callback: ProgressCallback | None = None,
    cancel_check: CancelCheck | None = None,
    staging_dir: Path | None = None,
) -> dict[str, Any]:
    """Decode ``input_path`` into ``output_dir`` and return its normalized metadata.

    The published directory is created only after probing, extraction, image checks,
    and manifest validation have all succeeded.
    """
    input_path = Path(input_path)
    output_dir = Path(output_dir)
    # 在创建输出前检查路径，避免覆盖已有数据。
    if output_dir.exists():
        raise FileExistsError(f"output directory already exists: {output_dir}")
    if not input_path.exists():
        raise FileNotFoundError(f"input video does not exist: {input_path}")
    if not input_path.is_file():
        raise ValueError(f"input video is not a file: {input_path}")
    if not output_dir.parent.is_dir():
        raise ValueError(f"output parent directory does not exist: {output_dir.parent}")
    # 先写入同级临时目录，全部校验通过后再发布。
    if staging_dir is None:
        staging_dir = output_dir.parent / f".{output_dir.name}.tmp-{uuid4().hex}"
    else:
        staging_dir = Path(staging_dir)
        if staging_dir == output_dir:
            raise ValueError("staging directory must differ from output directory")
        if staging_dir.parent.resolve() != output_dir.parent.resolve():
            raise ValueError("staging directory must be a sibling of the output directory")
    if staging_dir.exists():
        raise FileExistsError(f"staging directory already exists: {staging_dir}")

    staging_created = False
    try:
        _emit_progress(progress_callback, "running", "probe", 0, 1, 0.0, "Probing video")
        _raise_if_cancelled(cancel_check)
        probe = _probe_video(input_path, cancel_check)
        _raise_if_cancelled(cancel_check)
        _emit_progress(progress_callback, "running", "probe", 1, 1, 0.05, "Video probe complete")
        staging_dir.mkdir()
        staging_created = True
        frames_dir = staging_dir / "frames"
        frames_dir.mkdir()
        expected_frames = len(probe["timestamps"])
        _emit_progress(
            progress_callback,
            "running",
            "extract",
            0,
            expected_frames,
            0.05,
            "Extracting frames",
        )
        _extract_frames(
            input_path,
            frames_dir,
            expected_frames,
            progress_callback,
            cancel_check,
        )
        frame_paths = _normalize_frame_names(frames_dir, cancel_check)
        if len(probe["timestamps"]) != len(frame_paths):
            raise ValueError(
                "video timestamp count does not match extracted frame count "
                f"({len(probe['timestamps'])} != {len(frame_paths)})"
            )
        _emit_progress(
            progress_callback,
            "running",
            "extract",
            expected_frames,
            expected_frames,
            0.8,
            "Frame extraction complete",
        )
        _emit_progress(
            progress_callback,
            "running",
            "validate",
            0,
            len(frame_paths),
            0.8,
            "Validating frames",
        )
        width, height, similarity_scores = _validate_and_score_frames(
            frame_paths, progress_callback, cancel_check
        )
        manifest = _build_manifest(
            input_path,
            probe,
            frame_paths,
            width,
            height,
            similarity_scores,
            cancel_check,
        )
        _validate_manifest(manifest)
        _raise_if_cancelled(cancel_check)
        _emit_progress(
            progress_callback,
            "running",
            "publish",
            0,
            1,
            0.95,
            "Publishing normalized source",
        )
        _write_manifest(staging_dir / "manifest.json", manifest)
        _raise_if_cancelled(cancel_check)
        staging_dir.replace(output_dir)
        staging_created = False
        _emit_progress(
            progress_callback,
            "completed",
            "publish",
            1,
            1,
            1.0,
            "Import complete",
        )
        return manifest
    except Exception:
        if staging_created and staging_dir.exists():
            shutil.rmtree(staging_dir)
        raise


def _emit_progress(
    callback: ProgressCallback | None,
    state: str,
    stage: str,
    completed: int,
    total: int,
    fraction: float,
    message: str,
) -> None:
    if callback is None:
        return
    callback(
        {
            "version": 1,
            "state": state,
            "stage": stage,
            "completed": completed,
            "total": total,
            "fraction": min(1.0, max(0.0, fraction)),
            "message": message,
        }
    )


def _raise_if_cancelled(cancel_check: CancelCheck | None) -> None:
    if cancel_check is not None and cancel_check():
        raise VideoImportCancelled("video import cancelled")


def _probe_video(
    input_path: Path, cancel_check: CancelCheck | None = None
) -> dict[str, Any]:
    payload = _run_json(
        [
            _media_tool("ffprobe"),
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
        cancel_check,
    )
    streams = payload.get("streams")
    if not isinstance(streams, list) or len(streams) != 1 or not isinstance(streams[0], dict):
        raise ValueError("video has no readable video stream")
    stream = streams[0]
    width, height = stream.get("width"), stream.get("height")
    if type(width) is not int or type(height) is not int or width <= 0 or height <= 0:
        raise ValueError("video has invalid dimensions")
    # 优先使用平均帧率，缺失时回退到流帧率。
    nominal_fps = _parse_fps(stream.get("avg_frame_rate"))
    if nominal_fps is None:
        nominal_fps = _parse_fps(stream.get("r_frame_rate"))
    if nominal_fps is None:
        raise ValueError("video has no valid nominal frame rate")

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
            timestamp = float(raw_timestamp)  # 标准化为秒数浮点值。
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


def _run_json(
    command: list[str], action: str, cancel_check: CancelCheck | None = None
) -> dict[str, Any]:
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as output_file, \
        tempfile.TemporaryFile(mode="w+", encoding="utf-8") as error_file:
        try:
            process = subprocess.Popen(
                command, stdout=output_file, stderr=error_file, text=True
            )
        except OSError as error:
            raise ValueError(f"could not run {command[0]} for video {action}: {error}") from None
        try:
            while process.poll() is None:
                _raise_if_cancelled(cancel_check)
                time.sleep(0.05)
            return_code = process.wait()
        except BaseException:
            _stop_process(process)
            raise
        output_file.seek(0)
        stdout = output_file.read()
        error_file.seek(0)
        stderr = error_file.read()
    if return_code != 0:
        detail = stderr.strip() or "unknown error"
        raise ValueError(f"video {action} failed: {detail}")
    try:
        payload = json.loads(stdout)
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


def _extract_frames(
    input_path: Path,
    frames_dir: Path,
    expected_frames: int,
    progress_callback: ProgressCallback | None,
    cancel_check: CancelCheck | None,
) -> None:
    command = [
        _media_tool("ffmpeg"),
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostats",
        "-progress",
        "pipe:1",
        "-i",
        str(input_path),
        "-map",
        "0:v:0",
        "-vsync",
        "0",
        str(frames_dir / "frame_%06d.png"),
    ]
    _raise_if_cancelled(cancel_check)
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as error_file:
        try:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=error_file,
                text=True,
                bufsize=1,
            )
        except OSError as error:
            raise ValueError(f"could not run ffmpeg: {error}") from None
        try:
            assert process.stdout is not None
            last_completed = 0
            while process.poll() is None:
                _raise_if_cancelled(cancel_check)
                ready, _, _ = select.select([process.stdout], [], [], 0.1)
                if not ready:
                    continue
                line = process.stdout.readline().strip()
                if not line.startswith("frame="):
                    continue
                try:
                    completed = int(line.split("=", 1)[1])
                except ValueError:
                    continue
                completed = min(expected_frames, max(last_completed, completed))
                if completed == last_completed:
                    continue
                last_completed = completed
                fraction = 0.05 + 0.75 * completed / max(1, expected_frames)
                _emit_progress(
                    progress_callback,
                    "running",
                    "extract",
                    completed,
                    expected_frames,
                    fraction,
                    "Extracting frame %d of %d" % (completed, expected_frames),
                )
            return_code = process.wait()
        except BaseException:
            _stop_process(process)
            raise
        if return_code != 0:
            error_file.seek(0)
            detail = error_file.read().strip() or "unknown error"
            raise ValueError(f"video decode failed: {detail}")


def _stop_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def _normalize_frame_names(
    frames_dir: Path, cancel_check: CancelCheck | None = None
) -> list[Path]:
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
        _raise_if_cancelled(cancel_check)
        temporary_path = frames_dir / f".renaming_{index:06d}.png"
        source_path.replace(temporary_path)
        temporary_paths.append(temporary_path)
    normalized_paths: list[Path] = []
    for index, temporary_path in enumerate(temporary_paths):
        _raise_if_cancelled(cancel_check)
        normalized_path = frames_dir / f"frame_{index:06d}.png"
        temporary_path.replace(normalized_path)
        normalized_paths.append(normalized_path)
    return normalized_paths


def _validate_and_score_frames(
    frame_paths: list[Path],
    progress_callback: ProgressCallback | None = None,
    cancel_check: CancelCheck | None = None,
) -> tuple[int, int, list[float]]:
    """Check one decoded image at a time and retain only adjacent frames."""
    previous_image: np.ndarray | None = None
    decoded_shape: tuple[int, int, int] | None = None
    similarity_scores: list[float] = []
    for index, frame_path in enumerate(frame_paths):
        _raise_if_cancelled(cancel_check)
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
        completed = index + 1
        _emit_progress(
            progress_callback,
            "running",
            "validate",
            completed,
            len(frame_paths),
            min(0.95, 0.8 + 0.15 * completed / max(1, len(frame_paths))),
            "Validating frame %d of %d" % (completed, len(frame_paths)),
        )
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
    cancel_check: CancelCheck | None = None,
) -> dict[str, Any]:
    source_sha256 = _sha256_file(input_path, cancel_check)
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


def _sha256_file(path: Path, cancel_check: CancelCheck | None = None) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            _raise_if_cancelled(cancel_check)
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
