import json
import os
from pathlib import Path
import subprocess
import sys

import cv2
import numpy as np
import pytest

from annotation_data.contracts import validate_instance, validate_manifest_semantics
import annotation_data.frame_source as frame_source_module
from annotation_data.frame_source import VideoImportCancelled, decode_video


ROOT = Path(__file__).resolve().parents[2]
PROJECT_MEDIA_BIN = ROOT / ".tools" / "ffmpeg" / "bin"
FFMPEG = str(PROJECT_MEDIA_BIN / "ffmpeg")
FFPROBE = str(PROJECT_MEDIA_BIN / "ffprobe")


def test_project_media_tools_are_required_for_video_integration() -> None:
    """The real video suite must fail, never skip, when local tools are absent."""
    for name, path in (("ffmpeg", FFMPEG), ("ffprobe", FFPROBE)):
        assert Path(path).is_file(), f"missing project media tool: {path}"
        assert os.access(path, os.X_OK), f"project media tool is not executable: {path}"
        assert frame_source_module._media_tool(name) == path


def make_three_frame_video(tmp_path: Path) -> Path:
    source_dir = tmp_path / "source"
    source_dir.mkdir()
    for index, color in enumerate(((0, 0, 0), (80, 30, 10), (200, 180, 20)), start=1):
        image = np.full((24, 32, 3), color, dtype=np.uint8)
        assert cv2.imwrite(str(source_dir / f"source_{index:02d}.png"), image)
    video_path = tmp_path / "three-frames.mkv"
    result = subprocess.run(
        [
            FFMPEG,
            "-hide_banner",
            "-loglevel",
            "error",
            "-framerate",
            "2",
            "-i",
            str(source_dir / "source_%02d.png"),
            "-c:v",
            "ffv1",
            str(video_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return video_path


def make_two_stream_video(tmp_path: Path) -> Path:
    first_dir = tmp_path / "first"
    second_dir = tmp_path / "second"
    first_dir.mkdir()
    second_dir.mkdir()
    for index in range(1, 4):
        assert cv2.imwrite(
            str(first_dir / f"frame_{index:02d}.png"),
            np.full((24, 32, 3), 30 * index, dtype=np.uint8),
        )
        assert cv2.imwrite(
            str(second_dir / f"frame_{index:02d}.png"),
            np.full((48, 64, 3), 60 * index, dtype=np.uint8),
        )
    video_path = tmp_path / "two-streams.mkv"
    result = subprocess.run(
        [
            FFMPEG,
            "-hide_banner",
            "-loglevel",
            "error",
            "-framerate",
            "2",
            "-i",
            str(first_dir / "frame_%02d.png"),
            "-framerate",
            "2",
            "-i",
            str(second_dir / "frame_%02d.png"),
            "-map",
            "0:v:0",
            "-map",
            "1:v:0",
            "-c:v",
            "ffv1",
            "-disposition:v:0",
            "0",
            "-disposition:v:1",
            "default",
            str(video_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return video_path


def make_rotated_video(tmp_path: Path) -> Path:
    source_dir = tmp_path / "rotated-source"
    source_dir.mkdir()
    for index, color in enumerate(((20, 40, 80), (50, 90, 140), (90, 150, 210)), start=1):
        image = np.full((24, 32, 3), color, dtype=np.uint8)
        assert cv2.imwrite(str(source_dir / f"source_{index:02d}.png"), image)

    base_path = tmp_path / "unrotated.mp4"
    encode_result = subprocess.run(
        [
            FFMPEG,
            "-hide_banner",
            "-loglevel",
            "error",
            "-framerate",
            "2",
            "-i",
            str(source_dir / "source_%02d.png"),
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            str(base_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert encode_result.returncode == 0, encode_result.stderr

    rotated_path = tmp_path / "rotated.mp4"
    rotate_result = subprocess.run(
        [
            FFMPEG,
            "-hide_banner",
            "-loglevel",
            "error",
            "-display_rotation",
            "90",
            "-i",
            str(base_path),
            "-c",
            "copy",
            str(rotated_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert rotate_result.returncode == 0, rotate_result.stderr
    return rotated_path


def make_negative_pts_video(tmp_path: Path) -> Path:
    source_dir = tmp_path / "negative-pts-source"
    source_dir.mkdir()
    for index in range(1, 5):
        image = np.full((24, 32, 3), 40 * index, dtype=np.uint8)
        assert cv2.imwrite(str(source_dir / f"source_{index:02d}.png"), image)

    video_path = tmp_path / "negative-pts.mkv"
    result = subprocess.run(
        [
            FFMPEG,
            "-hide_banner",
            "-loglevel",
            "error",
            "-framerate",
            "2",
            "-i",
            str(source_dir / "source_%02d.png"),
            "-vf",
            "setpts=PTS-1/TB",
            "-fps_mode",
            "passthrough",
            "-avoid_negative_ts",
            "disabled",
            "-c:v",
            "ffv1",
            str(video_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return video_path


def make_timestamp_less_h264(tmp_path: Path) -> Path:
    source_dir = tmp_path / "raw-h264-source"
    source_dir.mkdir()
    for index, color in enumerate(((20, 10, 60), (80, 40, 120), (160, 90, 220)), start=1):
        image = np.full((24, 32, 3), color, dtype=np.uint8)
        assert cv2.imwrite(str(source_dir / f"source_{index:02d}.png"), image)

    video_path = tmp_path / "timestamp-less.h264"
    result = subprocess.run(
        [
            FFMPEG,
            "-hide_banner",
            "-loglevel",
            "error",
            "-framerate",
            "25",
            "-i",
            str(source_dir / "source_%02d.png"),
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-f",
            "h264",
            str(video_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return video_path


def make_variable_frame_rate_video(tmp_path: Path) -> Path:
    source_dir = tmp_path / "vfr-source"
    source_dir.mkdir()
    paths: list[Path] = []
    for index, color in enumerate(((10, 40, 80), (80, 120, 30), (180, 30, 150)), start=1):
        path = source_dir / f"source_{index:02d}.png"
        assert cv2.imwrite(str(path), np.full((24, 32, 3), color, dtype=np.uint8))
        paths.append(path)
    concat_path = tmp_path / "vfr-concat.txt"
    concat_path.write_text(
        "".join(
            (
                f"file '{paths[0].as_posix()}'\n",
                "duration 0.04\n",
                f"file '{paths[1].as_posix()}'\n",
                "duration 0.24\n",
                f"file '{paths[2].as_posix()}'\n",
                "duration 0.08\n",
                f"file '{paths[2].as_posix()}'\n",
            )
        ),
        encoding="utf-8",
    )
    video_path = tmp_path / "variable-rate.mkv"
    result = subprocess.run(
        [
            FFMPEG,
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            str(concat_path),
            "-fps_mode",
            "vfr",
            "-c:v",
            "ffv1",
            str(video_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return video_path


def test_decode_video_normalizes_a_real_lossless_video(tmp_path: Path) -> None:
    video_path = make_three_frame_video(tmp_path)
    output_dir = tmp_path / "normalized"

    result = decode_video(video_path, output_dir)

    manifest = json.loads((output_dir / "manifest.json").read_text(encoding="utf-8"))
    assert validate_instance(manifest, "dataset-manifest-v1.schema.json") == []
    assert validate_manifest_semantics(manifest) == []
    assert [entry["frame"] for entry in manifest["frames"]] == [0, 1, 2]
    assert [entry["image_path"] for entry in manifest["frames"]] == [
        "frames/frame_000000.png",
        "frames/frame_000001.png",
        "frames/frame_000002.png",
    ]
    assert [entry["time_s"] for entry in manifest["frames"]] == sorted(
        entry["time_s"] for entry in manifest["frames"]
    )
    assert (manifest["width"], manifest["height"], manifest["nominal_fps"]) == (32, 24, 2.0)
    assert len(result["similarity_scores"]) == 2
    assert all(0.0 <= score <= 1.0 for score in result["similarity_scores"])
    assert manifest["similarity_scores"] == result["similarity_scores"]
    for entry in manifest["frames"]:
        image = cv2.imread(str(output_dir / entry["image_path"]), cv2.IMREAD_COLOR)
        assert image is not None
        assert image.shape == (24, 32, 3)


def test_decode_video_uses_project_tools_when_gui_path_has_no_ffmpeg(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    video_path = make_three_frame_video(tmp_path)
    empty_path = tmp_path / "empty-path"
    empty_path.mkdir()
    monkeypatch.setenv("PATH", str(empty_path))

    result = decode_video(video_path, tmp_path / "normalized")

    assert result["frame_count"] == 3


def test_media_tool_missing_error_names_project_path_and_path_fallback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    empty_project_bin = tmp_path / "project-tools"
    empty_project_bin.mkdir()
    empty_path = tmp_path / "empty-path"
    empty_path.mkdir()
    monkeypatch.setattr(frame_source_module, "_PROJECT_MEDIA_BIN", empty_project_bin)
    monkeypatch.setenv("PATH", str(empty_path))

    with pytest.raises(FileNotFoundError) as caught:
        frame_source_module._media_tool("ffprobe")

    message = str(caught.value)
    assert "ffprobe" in message
    assert str(empty_project_bin / "ffprobe") in message
    assert "PATH" in message


def test_decode_video_uses_first_stream_even_when_second_is_default(tmp_path: Path) -> None:
    video_path = make_two_stream_video(tmp_path)
    output_dir = tmp_path / "normalized"

    result = decode_video(video_path, output_dir)

    assert (result["width"], result["height"], result["frame_count"]) == (32, 24, 3)
    assert len(result["similarity_scores"]) == 2
    assert all(
        cv2.imread(str(path), cv2.IMREAD_COLOR).shape == (24, 32, 3)
        for path in sorted((output_dir / "frames").glob("*.png"))
    )


def test_decode_video_uses_display_oriented_pixel_dimensions(tmp_path: Path) -> None:
    video_path = make_rotated_video(tmp_path)
    output_dir = tmp_path / "normalized"

    result = decode_video(video_path, output_dir)

    assert (result["width"], result["height"], result["frame_count"]) == (24, 32, 3)
    assert all(
        cv2.imread(str(path), cv2.IMREAD_COLOR).shape == (32, 24, 3)
        for path in sorted((output_dir / "frames").glob("*.png"))
    )


def test_decode_video_normalizes_negative_start_time_without_changing_intervals(
    tmp_path: Path,
) -> None:
    video_path = make_negative_pts_video(tmp_path)
    output_dir = tmp_path / "normalized"

    result = decode_video(video_path, output_dir)

    assert result["frame_count"] == 4
    assert [entry["frame"] for entry in result["frames"]] == [0, 1, 2, 3]
    assert [entry["time_s"] for entry in result["frames"]] == pytest.approx(
        [0.0, 0.5, 1.0, 1.5]
    )


def test_decode_video_synthesizes_times_when_all_frame_timestamps_are_missing(
    tmp_path: Path,
) -> None:
    video_path = make_timestamp_less_h264(tmp_path)
    probe_result = subprocess.run(
        [
            FFPROBE,
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_frames",
            "-show_entries",
            "frame=best_effort_timestamp_time",
            "-of",
            "json",
            str(video_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert probe_result.returncode == 0, probe_result.stderr
    probed_frames = json.loads(probe_result.stdout)["frames"]
    assert probed_frames
    assert all("best_effort_timestamp_time" not in frame for frame in probed_frames)

    result = decode_video(video_path, tmp_path / "normalized")

    assert result["frame_count"] == 3
    assert [entry["frame"] for entry in result["frames"]] == [0, 1, 2]
    assert [entry["time_s"] for entry in result["frames"]] == pytest.approx(
        [0.0, 0.04, 0.08]
    )


def test_decode_video_preserves_variable_frame_intervals(tmp_path: Path) -> None:
    video_path = make_variable_frame_rate_video(tmp_path)

    result = decode_video(video_path, tmp_path / "normalized")

    timestamps = [float(entry["time_s"]) for entry in result["frames"]]
    intervals = [right - left for left, right in zip(timestamps, timestamps[1:])]
    assert result["frame_count"] == 4
    assert timestamps == sorted(timestamps)
    assert min(intervals) > 0.0
    assert max(intervals) - min(intervals) >= 0.10


def test_decode_video_rejects_output_collision_without_overwriting(tmp_path: Path) -> None:
    output_dir = tmp_path / "already-there"
    output_dir.mkdir()
    sentinel = output_dir / "keep.txt"
    sentinel.write_text("keep", encoding="utf-8")

    with pytest.raises(FileExistsError, match="already exists"):
        decode_video(tmp_path / "missing-video.mkv", output_dir)

    assert sentinel.read_text(encoding="utf-8") == "keep"


@pytest.mark.parametrize("input_name", ["missing-video.mkv", "not-a-video.mkv"])
def test_decode_video_rejects_missing_and_invalid_videos(tmp_path: Path, input_name: str) -> None:
    input_path = tmp_path / input_name
    if input_name == "not-a-video.mkv":
        input_path.write_text("definitely not video data", encoding="utf-8")
    output_dir = tmp_path / "normalized"

    with pytest.raises((FileNotFoundError, ValueError)):
        decode_video(input_path, output_dir)

    assert not output_dir.exists()


def test_cli_writes_failure_result_without_traceback(tmp_path: Path) -> None:
    result_path = tmp_path / "result.json"
    command = [
        sys.executable,
        str(ROOT / "python/frame_source.py"),
        str(tmp_path / "missing.mkv"),
        "--output",
        str(tmp_path / "normalized"),
        "--result-file",
        str(result_path),
    ]

    result = subprocess.run(command, cwd=ROOT, check=False, capture_output=True, text=True)

    assert result.returncode != 0
    assert "Traceback" not in result.stderr
    assert json.loads(result_path.read_text(encoding="utf-8"))["success"] is False


def test_cli_writes_success_result_for_normalized_video(tmp_path: Path) -> None:
    video_path = make_three_frame_video(tmp_path)
    output_dir = tmp_path / "normalized"
    result_path = tmp_path / "result.json"
    command = [
        sys.executable,
        str(ROOT / "python/frame_source.py"),
        str(video_path),
        "--output",
        str(output_dir),
        "--result-file",
        str(result_path),
    ]

    result = subprocess.run(command, cwd=ROOT, check=False, capture_output=True, text=True)

    assert result.returncode == 0, result.stderr
    assert "Traceback" not in result.stderr
    assert json.loads(result_path.read_text(encoding="utf-8")) == {
        "success": True,
        "path": str(output_dir),
    }


def test_decode_video_reports_monotonic_versioned_progress(tmp_path: Path) -> None:
    video_path = make_three_frame_video(tmp_path)
    events: list[dict[str, object]] = []

    decode_video(video_path, tmp_path / "normalized", progress_callback=events.append)

    assert events
    assert all(
        set(event) == {
            "version",
            "state",
            "stage",
            "completed",
            "total",
            "fraction",
            "message",
        }
        for event in events
    )
    assert all(event["version"] == 1 for event in events)
    assert [float(event["fraction"]) for event in events] == sorted(
        float(event["fraction"]) for event in events
    )
    assert {event["stage"] for event in events} == {
        "probe",
        "extract",
        "validate",
        "publish",
    }
    assert events[-1]["state"] == "completed"
    assert events[-1]["stage"] == "publish"
    assert events[-1]["fraction"] == 1.0


def test_decode_video_cooperative_cancel_removes_only_owned_staging(tmp_path: Path) -> None:
    video_path = make_three_frame_video(tmp_path)
    output_dir = tmp_path / "normalized"
    staging_dir = tmp_path / ".normalized.import-test"
    cancel_requested = False

    def capture(event: dict[str, object]) -> None:
        nonlocal cancel_requested
        if event["stage"] == "extract" and event["completed"] == 0:
            cancel_requested = True

    with pytest.raises(VideoImportCancelled, match="cancelled"):
        decode_video(
            video_path,
            output_dir,
            progress_callback=capture,
            cancel_check=lambda: cancel_requested,
            staging_dir=staging_dir,
        )

    assert video_path.exists()
    assert not output_dir.exists()
    assert not staging_dir.exists()


def test_decode_video_cancel_terminates_its_running_ffmpeg_child(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    video_path = make_three_frame_video(tmp_path)
    output_dir = tmp_path / "normalized"
    staging_dir = tmp_path / ".normalized.running-child"
    real_popen = subprocess.Popen
    child_started = False

    def recording_popen(*args, **kwargs):
        nonlocal child_started
        command = args[0]
        if command and Path(command[0]).name == "ffmpeg":
            child_started = True
        return real_popen(*args, **kwargs)

    monkeypatch.setattr(frame_source_module.subprocess, "Popen", recording_popen)

    with pytest.raises(VideoImportCancelled, match="cancelled"):
        decode_video(
            video_path,
            output_dir,
            cancel_check=lambda: child_started,
            staging_dir=staging_dir,
        )

    assert child_started
    assert video_path.exists()
    assert not output_dir.exists()
    assert not staging_dir.exists()


def test_decode_video_accepts_new_explicit_sibling_staging_path(tmp_path: Path) -> None:
    video_path = make_three_frame_video(tmp_path)
    output_dir = tmp_path / "normalized"
    staging_dir = tmp_path / ".normalized.import-test"

    decode_video(video_path, output_dir, staging_dir=staging_dir)

    assert output_dir.is_dir()
    assert not staging_dir.exists()


def test_cli_writes_atomic_progress_and_completed_state(tmp_path: Path) -> None:
    video_path = make_three_frame_video(tmp_path)
    output_dir = tmp_path / "normalized"
    result_path = tmp_path / "result.json"
    progress_path = tmp_path / "progress.json"
    staging_path = tmp_path / ".normalized.cli-test"
    command = [
        sys.executable,
        str(ROOT / "python/frame_source.py"),
        str(video_path),
        "--output",
        str(output_dir),
        "--result-file",
        str(result_path),
        "--progress-file",
        str(progress_path),
        "--cancel-file",
        str(tmp_path / "cancel.request"),
        "--staging-dir",
        str(staging_path),
    ]

    result = subprocess.run(command, cwd=ROOT, check=False, capture_output=True, text=True)

    assert result.returncode == 0, result.stderr
    progress = json.loads(progress_path.read_text(encoding="utf-8"))
    assert progress == {
        "version": 1,
        "state": "completed",
        "stage": "publish",
        "completed": 1,
        "total": 1,
        "fraction": 1.0,
        "message": "Import complete",
    }
    assert json.loads(result_path.read_text(encoding="utf-8")) == {
        "success": True,
        "path": str(output_dir),
    }
    assert not staging_path.exists()
