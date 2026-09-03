import json
from pathlib import Path
import subprocess
import sys

import cv2
import numpy as np
import pytest

from annotool.contracts import validate_instance, validate_manifest_semantics
from annotool.frame_source import decode_video


ROOT = Path(__file__).resolve().parents[2]


def make_three_frame_video(tmp_path: Path) -> Path:
    source_dir = tmp_path / "source"
    source_dir.mkdir()
    for index, color in enumerate(((0, 0, 0), (80, 30, 10), (200, 180, 20)), start=1):
        image = np.full((24, 32, 3), color, dtype=np.uint8)
        assert cv2.imwrite(str(source_dir / f"source_{index:02d}.png"), image)
    video_path = tmp_path / "three-frames.mkv"
    result = subprocess.run(
        [
            "ffmpeg",
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
    for entry in manifest["frames"]:
        image = cv2.imread(str(output_dir / entry["image_path"]), cv2.IMREAD_COLOR)
        assert image is not None
        assert image.shape == (24, 32, 3)


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
