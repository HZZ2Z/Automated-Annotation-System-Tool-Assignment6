"""Tests for the read-only real-runtime Model Assist smoke harness."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
from types import SimpleNamespace

import cv2
import numpy as np
import pytest

import model_assist_smoke
from model_assist_smoke import (
    create_job_dir,
    normalize_prompts,
    png_size,
    run,
    validate_candidate,
)


def _png(path: Path, image: np.ndarray) -> str:
    assert cv2.imwrite(str(path), image)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_png_size_and_default_prompt_use_image_coordinates(tmp_path):
    image = np.zeros((48, 80, 3), np.uint8)
    digest = _png(tmp_path / "frame.png", image)

    assert png_size((tmp_path / "frame.png").read_bytes()) == (80, 48)
    assert len(digest) == 64
    assert normalize_prompts([], [], None, 80, 48) == {
        "points": [[39.5, 23.5]], "labels": [1], "box": None,
    }


def test_prompt_normalization_preserves_labels_and_rejects_out_of_bounds():
    assert normalize_prompts([[10, 11]], [[20, 21]], [1, 2, 30, 40], 80, 48) == {
        "points": [[10.0, 11.0], [20.0, 21.0]],
        "labels": [1, 0],
        "box": [1.0, 2.0, 30.0, 40.0],
    }
    with pytest.raises(ValueError, match="bounds"):
        normalize_prompts([[80, 2]], [], None, 80, 48)
    with pytest.raises(ValueError, match="box"):
        normalize_prompts([], [], [3, 4, 3, 20], 80, 48)


def test_job_creation_never_reuses_or_overwrites_an_existing_directory(tmp_path):
    output = tmp_path / "evidence"
    assert create_job_dir(output) == output.resolve()
    sentinel = output / "sentinel.txt"
    sentinel.write_text("keep", encoding="utf-8")
    with pytest.raises(FileExistsError):
        create_job_dir(output)
    assert sentinel.read_text(encoding="utf-8") == "keep"


def test_repository_local_job_must_be_below_designated_ignored_root(tmp_path, monkeypatch):
    monkeypatch.setattr(model_assist_smoke, "_REPO_ROOT", tmp_path)
    unsafe = tmp_path / "review-evidence"
    with pytest.raises(ValueError, match=".local-acceptance"):
        create_job_dir(unsafe)
    assert not unsafe.exists()

    safe = tmp_path / ".local-acceptance" / "model-assist-001"
    assert create_job_dir(safe) == safe.resolve()


def test_candidate_validation_checks_scope_hash_binary_pixels_and_roi(tmp_path):
    job = create_job_dir(tmp_path / "evidence")
    candidate_dir = job / "candidates"
    candidate_dir.mkdir()
    mask = np.zeros((20, 30), np.uint8)
    mask[2:18, 4:26] = 255
    digest = _png(candidate_dir / "mask.png", mask)
    descriptor = {
        "path": "candidates/mask.png",
        "roi": [5, 6, 30, 20],
        "sha256": digest,
        "score": 0.875,
    }

    evidence = validate_candidate(job, descriptor, (80, 48))

    assert evidence["sha256"] == digest
    assert evidence["roi"] == [5, 6, 30, 20]
    assert evidence["foreground_pixels"] == 16 * 22
    mask[0, 0] = 17
    _png(candidate_dir / "nonbinary.png", mask)
    bad = {**descriptor, "path": "candidates/nonbinary.png"}
    bad["sha256"] = hashlib.sha256((candidate_dir / "nonbinary.png").read_bytes()).hexdigest()
    with pytest.raises(ValueError, match="binary"):
        validate_candidate(job, bad, (80, 48))

    encoded, pgm = cv2.imencode(".pgm", mask)
    assert encoded
    disguised = candidate_dir / "disguised.png"
    disguised.write_bytes(pgm.tobytes())
    disguised_descriptor = {**descriptor, "path": "candidates/disguised.png"}
    disguised_descriptor["sha256"] = hashlib.sha256(disguised.read_bytes()).hexdigest()
    with pytest.raises(ValueError, match="PNG"):
        validate_candidate(job, disguised_descriptor, (80, 48))

    link = candidate_dir / "link.png"
    link.symlink_to(candidate_dir / "mask.png")
    linked = {**descriptor, "path": "candidates/link.png"}
    with pytest.raises(ValueError, match="symlink"):
        validate_candidate(job, linked, (80, 48))


def _smoke_case(tmp_path):
    image = np.zeros((48, 80, 3), np.uint8)
    image_path = tmp_path / "frame.png"
    _png(image_path, image)
    config = tmp_path / "config.yaml"
    checkpoint = tmp_path / "checkpoint.pt"
    config.write_text("model: {}\n", encoding="utf-8")
    checkpoint.write_bytes(b"official-placeholder")
    output = tmp_path / "evidence"
    fake_worker = Path(__file__).resolve().parents[1] / "fixtures" / "fake_model_assist_worker.py"
    args = SimpleNamespace(
        python=str(Path(sys.executable).absolute()),
        config=str(config.resolve()),
        checkpoint=str(checkpoint.resolve()),
        image=str(image_path.resolve()),
        output_dir=str(output),
        device="cpu",
        positive_point=[[20.0, 20.0]],
        negative_point=[],
        box=None,
        frame_id=17,
        playback_index=2,
        load_timeout=5.0,
        predict_timeout=5.0,
    )

    def fake_probe(_python):
        return {
            "python_executable": sys.executable, "python_version": "test", "torch": "test",
            "torchvision": "test", "numpy": np.__version__, "opencv": cv2.__version__,
            "sam2_distribution": "test", "sam2_package": "test", "cuda_available": False,
            "cuda_device": None,
        }
    return args, fake_worker, fake_probe


def test_smoke_driver_closes_the_production_protocol_with_an_injected_worker(
    tmp_path, monkeypatch
):
    args, fake_worker, fake_probe = _smoke_case(tmp_path)
    monkeypatch.setenv("MODEL_ASSIST_FAKE_MODE", "ok")

    code, report_path = run(args, runtime_probe=fake_probe, worker_path=fake_worker)

    report = json.loads(report_path.read_text(encoding="utf-8"))
    assert code == 0 and report["status"] == "PASS"
    assert report["hello"]["backend"] == "fake-model-assist"
    assert report["inputs"]["frame_id"] == 17
    assert len(report["candidates"]) == 1
    assert report["worker_exit_code"] == 0
    assert (Path(args.output_dir) / "worker.stderr.log").read_bytes() == b""


@pytest.mark.parametrize(
    ("mode", "timeout", "message"),
    [("malformed", 5.0, "invalid protocol JSON"), ("delay", 0.05, "timed out")],
)
def test_smoke_driver_terminates_failed_worker_and_keeps_a_fail_report(
    tmp_path, monkeypatch, mode: str, timeout: float, message: str
):
    args, fake_worker, fake_probe = _smoke_case(tmp_path)
    args.predict_timeout = timeout
    monkeypatch.setenv("MODEL_ASSIST_FAKE_MODE", mode)

    code, report_path = run(args, runtime_probe=fake_probe, worker_path=fake_worker)

    report = json.loads(report_path.read_text(encoding="utf-8"))
    assert code == 1 and report["status"] == "FAIL"
    assert message in report["error"]
    assert isinstance(report["worker_exit_code"], int)
    assert report["worker_exit_code"] != 0
