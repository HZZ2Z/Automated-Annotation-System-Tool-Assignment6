"""Backend and process-loop tests for single-frame model assistance."""
from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import types

import cv2
import numpy as np
import pytest

from annotation_data.model_assist_backend import ModelAssistBackend
from model_assist_worker import run_loop


ROOT = Path(__file__).resolve().parents[2]
FAKE_WORKER = ROOT / "tests" / "fixtures" / "fake_model_assist_worker.py"


def _write_png(path: Path, image: np.ndarray) -> str:
    assert cv2.imwrite(str(path), image)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _image(job: Path, name: str = "input.png", *, width: int = 80, height: int = 60) -> tuple[Path, str]:
    y, x = np.indices((height, width))
    image = np.dstack(((x * 3) % 255, (y * 5) % 255, ((x + y) * 7) % 255)).astype(np.uint8)
    path = job / name
    return path, _write_png(path, image)


class FakePredictor:
    def __init__(self, masks: np.ndarray | None = None, scores: np.ndarray | None = None):
        self.images: list[np.ndarray] = []
        self.calls: list[dict] = []
        default = np.zeros((3, 60, 80), dtype=bool)
        default[0, 10:30, 12:42] = True
        default[1, 8:32, 10:45] = True
        default[2, 12:28, 15:39] = True
        self.masks = default if masks is None else masks
        self.scores = np.asarray([0.9, 0.7, 0.5], np.float32) if scores is None else scores

    def set_image(self, image: np.ndarray) -> None:
        self.images.append(image.copy())

    def predict(self, **kwargs):
        self.calls.append(kwargs)
        return self.masks.copy(), self.scores.copy(), np.zeros((len(self.masks), 256, 256), np.float32)


def _backend(job: Path, predictor: FakePredictor | None = None):
    predictor = predictor or FakePredictor()
    calls: list[tuple[str, str, str]] = []

    def factory(config: str, checkpoint: str, device: str):
        calls.append((config, checkpoint, device))
        return predictor

    backend = ModelAssistBackend(
        job, config_path="config.yaml", checkpoint_path="weights.pt",
        device="cpu", predictor_factory=factory,
    )
    return backend, predictor, calls


def _set_image(backend: ModelAssistBackend, job: Path) -> tuple[Path, str]:
    path, digest = _image(job)
    result = backend.set_image("input.png", digest, width=80, height=60)
    assert result == {"image_sha256": digest, "width": 80, "height": 60, "cached": False}
    return path, digest


def _install_fake_official_sam(monkeypatch, package_root: Path, *, cuda: bool = False):
    calls: list[tuple[str, str, str]] = []
    model = object()

    torch_module = types.ModuleType("torch")
    torch_module.cuda = types.SimpleNamespace(is_available=lambda: cuda)
    sam2_module = types.ModuleType("sam2")
    sam2_module.__path__ = [str(package_root)]
    build_module = types.ModuleType("sam2.build_sam")

    def build_sam2(config: str, checkpoint: str, *, device: str):
        calls.append((config, checkpoint, device))
        return model

    build_module.build_sam2 = build_sam2
    predictor_module = types.ModuleType("sam2.sam2_image_predictor")

    class Predictor(FakePredictor):
        def __init__(self, actual_model):
            super().__init__()
            assert actual_model is model

    predictor_module.SAM2ImagePredictor = Predictor
    monkeypatch.setitem(sys.modules, "torch", torch_module)
    monkeypatch.setitem(sys.modules, "sam2", sam2_module)
    monkeypatch.setitem(sys.modules, "sam2.build_sam", build_module)
    monkeypatch.setitem(sys.modules, "sam2.sam2_image_predictor", predictor_module)
    return calls


def test_official_predictor_translates_absolute_installed_config_to_hydra_name(
    tmp_path, monkeypatch
):
    package_root = tmp_path / "site-packages" / "sam2"
    config = package_root / "configs" / "sam2.1" / "sam2.1_hiera_t.yaml"
    checkpoint = tmp_path / "sam2.1_hiera_tiny.pt"
    config.parent.mkdir(parents=True)
    config.write_text("model: {}\n", encoding="utf-8")
    checkpoint.write_bytes(b"checkpoint")
    calls = _install_fake_official_sam(monkeypatch, package_root)

    predictor = ModelAssistBackend._official_predictor(
        str(config.resolve()), str(checkpoint.resolve()), "auto"
    )

    assert calls == [(
        "configs/sam2.1/sam2.1_hiera_t.yaml", str(checkpoint.resolve()), "cpu"
    )]
    assert predictor.model_assist_device == "cpu"


def test_official_predictor_rejects_config_outside_installed_sam2_package(
    tmp_path, monkeypatch
):
    package_root = tmp_path / "site-packages" / "sam2"
    package_root.mkdir(parents=True)
    config = tmp_path / "custom.yaml"
    checkpoint = tmp_path / "sam2.1_hiera_tiny.pt"
    config.write_text("model: {}\n", encoding="utf-8")
    checkpoint.write_bytes(b"checkpoint")
    _install_fake_official_sam(monkeypatch, package_root)

    with pytest.raises(RuntimeError, match="installed sam2 package"):
        ModelAssistBackend._official_predictor(
            str(config.resolve()), str(checkpoint.resolve()), "cpu"
        )


def test_hello_loads_the_model_once_and_set_image_reuses_digest_embedding(tmp_path):
    backend, predictor, factory_calls = _backend(tmp_path)
    assert backend.hello()["device"] == "cpu"
    assert backend.hello()["device"] == "cpu"
    assert factory_calls == [("config.yaml", "weights.pt", "cpu")]
    _, digest = _set_image(backend, tmp_path)
    cached = backend.set_image("input.png", digest, width=80, height=60)
    assert cached["cached"] is True
    assert len(predictor.images) == 1

    second, second_digest = _image(tmp_path, "second.png")
    second.write_bytes(second.read_bytes() + b"different")
    second_digest = hashlib.sha256(second.read_bytes()).hexdigest()
    with pytest.raises(ValueError, match="decode"):
        backend.set_image("second.png", second_digest, width=80, height=60)

    _image(tmp_path, "second.png", width=81, height=60)
    second_digest = hashlib.sha256(second.read_bytes()).hexdigest()
    backend.set_image("second.png", second_digest, width=81, height=60)
    assert len(predictor.images) == 2


def test_hello_streams_checkpoint_hash_without_loading_the_whole_file(tmp_path, monkeypatch):
    checkpoint = tmp_path / "checkpoint.pt"
    checkpoint.write_bytes(b"checkpoint-payload")
    predictor = FakePredictor()
    backend = ModelAssistBackend(
        tmp_path,
        config_path="config.yaml",
        checkpoint_path=str(checkpoint),
        device="cpu",
        predictor_factory=lambda *_: predictor,
    )
    expected = hashlib.sha256(b"checkpoint-payload").hexdigest()

    monkeypatch.setattr(Path, "read_bytes", lambda _self: (_ for _ in ()).throw(
        AssertionError("checkpoint must be hashed in bounded chunks")
    ))

    assert backend.hello()["checkpoint_sha256"] == expected


def test_predict_forwards_points_labels_box_and_writes_bounded_binary_roi_pngs(tmp_path):
    backend, predictor, _ = _backend(tmp_path)
    backend.hello()
    _set_image(backend, tmp_path)

    result = backend.predict(
        points=[[12.0, 9.0], [50.0, 40.0]], labels=[1, 0],
        box=[5.0, 6.0, 60.0, 50.0], initial_mask=None,
    )

    call = predictor.calls[-1]
    np.testing.assert_array_equal(call["point_coords"], np.asarray([[12, 9], [50, 40]], np.float32))
    np.testing.assert_array_equal(call["point_labels"], np.asarray([1, 0], np.int32))
    np.testing.assert_array_equal(call["box"], np.asarray([5, 6, 60, 50], np.float32))
    assert call["mask_input"] is None and call["multimask_output"] is True
    assert len(result["candidates"]) == 3
    for candidate in result["candidates"]:
        assert set(candidate) == {"path", "roi", "sha256", "score"}
        candidate_path = tmp_path / candidate["path"]
        assert candidate_path.is_file() and not candidate_path.is_symlink()
        assert hashlib.sha256(candidate_path.read_bytes()).hexdigest() == candidate["sha256"]
        crop = cv2.imread(str(candidate_path), cv2.IMREAD_GRAYSCALE)
        assert crop is not None and set(np.unique(crop)).issubset({0, 255})
        assert [candidate["roi"][2], candidate["roi"][3]] == [crop.shape[1], crop.shape[0]]


def test_initial_full_image_mask_becomes_one_by_256_logits_with_nearest_semantics(tmp_path):
    backend, predictor, _ = _backend(tmp_path)
    backend.hello()
    _set_image(backend, tmp_path)
    mask = np.zeros((60, 80), np.uint8)
    mask[10:30, 20:50] = 255
    digest = _write_png(tmp_path / "initial.png", mask)

    backend.predict(
        points=[[25, 20]], labels=[1], box=None,
        initial_mask={"path": "initial.png", "sha256": digest, "width": 80, "height": 60},
    )

    logits = predictor.calls[-1]["mask_input"]
    assert logits.shape == (1, 256, 256) and logits.dtype == np.float32
    assert set(np.unique(logits)) == {-8.0, 8.0}
    expected = cv2.resize(mask, (256, 256), interpolation=cv2.INTER_NEAREST) > 0
    np.testing.assert_array_equal(logits[0] > 0, expected)


@pytest.mark.parametrize("kind", ["traversal", "absolute", "symlink", "directory", "digest", "dimensions"])
def test_set_image_rejects_untrusted_or_mismatched_inputs(tmp_path, kind: str):
    backend, _, _ = _backend(tmp_path)
    backend.hello()
    path, digest = _image(tmp_path)
    name: str = "input.png"
    width, height = 80, 60
    if kind == "traversal":
        name = "../input.png"
    elif kind == "absolute":
        name = str(path)
    elif kind == "symlink":
        (tmp_path / "link.png").symlink_to(path)
        name = "link.png"
    elif kind == "directory":
        (tmp_path / "folder.png").mkdir()
        name = "folder.png"
    elif kind == "digest":
        digest = "0" * 64
    else:
        width = 81
    with pytest.raises(ValueError):
        backend.set_image(name, digest, width=width, height=height)


def test_set_image_rejects_oversized_bytes_or_pixel_dimensions(tmp_path):
    backend, _, _ = _backend(tmp_path)
    backend.hello()
    path, digest = _image(tmp_path)
    backend.max_input_bytes = path.stat().st_size - 1
    with pytest.raises(ValueError, match="bytes"):
        backend.set_image("input.png", digest, width=80, height=60)

    backend.max_input_bytes = 64 * 1024 * 1024
    backend.max_image_pixels = 80 * 60 - 1
    with pytest.raises(ValueError, match="pixels"):
        backend.set_image("input.png", digest, width=80, height=60)


@pytest.mark.parametrize("kind", ["nonbinary", "wrong_size", "wrong_hash", "symlink"])
def test_initial_mask_rejects_nonbinary_mismatched_or_untrusted_files(tmp_path, kind: str):
    backend, _, _ = _backend(tmp_path)
    backend.hello()
    _set_image(backend, tmp_path)
    mask = np.zeros((60, 80), np.uint8)
    mask[10:30, 20:50] = 255
    if kind == "nonbinary":
        mask[0, 0] = 17
    elif kind == "wrong_size":
        mask = np.zeros((59, 80), np.uint8)
    path = tmp_path / "initial.png"
    digest = _write_png(path, mask)
    name = "initial.png"
    if kind == "wrong_hash":
        digest = "0" * 64
    elif kind == "symlink":
        (tmp_path / "mask-link.png").symlink_to(path)
        name = "mask-link.png"
    with pytest.raises(ValueError):
        backend.predict(points=[[1, 2]], labels=[1], box=None, initial_mask={
            "path": name, "sha256": digest, "width": 80, "height": 60,
        })


def test_predict_rechecks_current_image_digest_and_refuses_output_collision(tmp_path):
    backend, _, _ = _backend(tmp_path)
    backend.hello()
    path, _ = _set_image(backend, tmp_path)
    path.write_bytes(path.read_bytes() + b"stale")
    with pytest.raises(ValueError, match="changed"):
        backend.predict(points=[[1, 2]], labels=[1], box=None, initial_mask=None)

    backend, _, _ = _backend(tmp_path)
    _write_png(tmp_path / "input.png", np.zeros((60, 80, 3), np.uint8))
    digest = hashlib.sha256((tmp_path / "input.png").read_bytes()).hexdigest()
    backend.hello()
    backend.set_image("input.png", digest, width=80, height=60)
    candidate_dir = tmp_path / "candidates"
    candidate_dir.mkdir(exist_ok=True)
    (candidate_dir / "predict-000001-0.png").write_bytes(b"sentinel")
    with pytest.raises(ValueError, match="collision"):
        backend.predict(points=[[1, 2]], labels=[1], box=None, initial_mask=None)
    assert (candidate_dir / "predict-000001-0.png").read_bytes() == b"sentinel"


@pytest.mark.parametrize("masks,scores", [
    (np.zeros((0, 60, 80), bool), np.zeros((0,), np.float32)),
    (np.zeros((4, 60, 80), bool), np.zeros((4,), np.float32)),
    (np.zeros((1, 59, 80), bool), np.zeros((1,), np.float32)),
    (np.full((1, 60, 80), 0.5, np.float32), np.zeros((1,), np.float32)),
    (np.zeros((1, 60, 80), bool), np.asarray([np.nan], np.float32)),
    (np.zeros((2, 60, 80), bool), np.asarray([0.5], np.float32)),
])
def test_predict_rejects_malformed_predictor_output(tmp_path, masks, scores):
    backend, _, _ = _backend(tmp_path, FakePredictor(masks=masks, scores=scores))
    backend.hello()
    _set_image(backend, tmp_path)
    with pytest.raises(ValueError, match="predictor|candidate"):
        backend.predict(points=[[1, 2]], labels=[1], box=None, initial_mask=None)


def test_cancel_and_shutdown_are_idempotent_and_close_only_the_owned_predictor(tmp_path):
    class Closable(FakePredictor):
        closed = 0

        def close(self):
            self.closed += 1

    predictor = Closable()
    backend, _, _ = _backend(tmp_path, predictor)
    backend.hello()
    assert backend.cancel("r4") == {"target_request_id": "r4", "cancelled": True}
    backend.shutdown()
    backend.shutdown()
    assert predictor.closed == 1


class LoopBackend:
    def __init__(self):
        self.closed = False

    def hello(self): return {"backend": "fake", "device": "cpu"}
    def set_image(self, path, digest, *, width, height): return {"image_sha256": digest, "width": width, "height": height, "cached": False}
    def predict(self, *, points, labels, box, initial_mask): return {"candidates": []}
    def cancel(self, target): return {"target_request_id": target, "cancelled": True}
    def shutdown(self): self.closed = True


def test_process_loop_emits_only_strict_protocol_lines_and_closes_backend():
    context = {
        "session_id": "s", "frame_id": 1, "playback_index": 0,
        "image_sha256": "a" * 64, "record_sha256": "b" * 64,
        "selected_region_id": "", "prompt_revision": 1,
    }
    requests = [
        {"protocol": "model-assist-v1", "request_id": "r1", "op": "hello", "context": {}, "data": {}},
        {"protocol": "model-assist-v1", "request_id": "r2", "op": "predict", "context": context,
         "data": {"points": [[1, 2]], "labels": [1], "box": None, "initial_mask": None}},
        {"protocol": "model-assist-v1", "request_id": "r3", "op": "shutdown", "context": {}, "data": {}},
    ]
    source = io.BytesIO(b"".join((json.dumps(item) + "\n").encode() for item in requests))
    output = io.BytesIO()
    backend = LoopBackend()
    assert run_loop(backend, source, output) == 0
    responses = [json.loads(line) for line in output.getvalue().splitlines()]
    assert [item["request_id"] for item in responses] == ["r1", "r2", "r3"]
    assert all(set(item) == {"protocol", "request_id", "ok", "context", "data", "errors"} for item in responses)
    assert backend.closed


@pytest.mark.parametrize("mode", ["ok", "wrong_hash", "multi_component", "hole"])
def test_deterministic_fake_worker_creates_declared_scenarios_inside_job(tmp_path, mode: str):
    image = np.zeros((60, 80, 3), np.uint8)
    digest = _write_png(tmp_path / "input.png", image)
    env = os.environ.copy()
    env["MODEL_ASSIST_FAKE_MODE"] = mode
    process = subprocess.run(
        [sys.executable, str(FAKE_WORKER), "--job-dir", str(tmp_path)],
        input=(json.dumps({
            "protocol": "model-assist-v1", "request_id": "r1", "op": "predict",
            "context": {"session_id": "s", "frame_id": 1, "playback_index": 0,
                        "image_sha256": digest, "record_sha256": "b" * 64,
                        "selected_region_id": "", "prompt_revision": 1},
            "data": {"points": [[20, 20]], "labels": [1], "box": None, "initial_mask": None},
        }) + "\n" + json.dumps({
            "protocol": "model-assist-v1", "request_id": "r2", "op": "shutdown", "context": {}, "data": {},
        }) + "\n").encode(),
        cwd=ROOT, env=env, capture_output=True, timeout=10,
    )
    assert process.returncode == 0 and process.stderr == b""
    responses = [json.loads(line) for line in process.stdout.splitlines()]
    candidate = responses[0]["data"]["candidates"][0]
    candidate_path = tmp_path / candidate["path"]
    assert candidate_path.is_file() and candidate_path.resolve().is_relative_to(tmp_path.resolve())
    assert responses[-1]["request_id"] == "r2"
