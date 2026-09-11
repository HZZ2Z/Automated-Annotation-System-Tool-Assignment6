"""Behavior tests for the job-scoped SAM 2 video backend."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import sys
import types

import cv2
import numpy as np
import pytest

from annotation_data.sam_video_backend import SamVideoBackend


WIDTH = 16
HEIGHT = 12


def _write_png(path: Path, image: np.ndarray) -> str:
    ok, encoded = cv2.imencode(".png", image)
    assert ok
    payload = encoded.tobytes()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    return hashlib.sha256(payload).hexdigest()


def _frames(root: Path, count: int) -> list[dict]:
    result = []
    for index in range(count + 1):
        image = np.full((HEIGHT, WIDTH, 3), index, np.uint8)
        relative = f"frozen/frame-{index:02d}.png"
        digest = _write_png(root / relative, image)
        result.append({
            "path": relative,
            "sha256": digest,
            "width": WIDTH,
            "height": HEIGHT,
            "playback_index": 4 + index,
            "frame_id": 11825 + index * 25,
        })
    return result


def _mask(root: Path) -> tuple[dict, np.ndarray]:
    image = np.zeros((HEIGHT, WIDTH), np.uint8)
    image[2:8, 3:11] = 255
    relative = "frozen/key-mask.png"
    digest = _write_png(root / relative, image)
    return {"path": relative, "sha256": digest, "roi": [0, 0, WIDTH, HEIGHT]}, image


class FakeVideoPredictor:
    sam_video_device = "cpu"

    def __init__(self) -> None:
        self.init_calls: list[str] = []
        self.loader_names: list[str] = []
        self.add_calls: list[dict] = []
        self.propagate_calls: list[dict] = []
        self.reset_calls: list[object] = []
        self.closed = 0
        self.crash = False
        self.mutate_before_crash = False
        self.output_frames: list[int] | None = None
        self.output_object_id = 1
        self.after_first_output = None
        self.tensor_like_output = False

    def init_state(self, *, video_path: str):
        print("predictor init diagnostic")
        loader_names = [
            name for name in os.listdir(video_path)
            if Path(name).suffix in {".jpg", ".jpeg", ".JPG", ".JPEG"}
        ]
        loader_names.sort(key=lambda name: int(Path(name).stem))
        if not loader_names:
            raise RuntimeError("official loader found no JPEG frames")
        if [int(Path(name).stem) for name in loader_names] != list(range(len(loader_names))):
            raise RuntimeError("official loader requires zero-based numeric frames")
        for name in loader_names:
            payload = (Path(video_path) / name).read_bytes()
            if not payload.startswith(b"\xff\xd8") or not payload.endswith(b"\xff\xd9"):
                raise RuntimeError("runtime frame is not a JPEG image")
            if cv2.imread(str(Path(video_path) / name), cv2.IMREAD_COLOR) is None:
                raise RuntimeError("runtime JPEG cannot be decoded")
        state = {"video_path": video_path, "serial": len(self.init_calls) + 1}
        self.init_calls.append(video_path)
        self.loader_names = loader_names
        return state

    def add_new_mask(self, *, inference_state, frame_idx: int, obj_id: int, mask):
        print("predictor add diagnostic")
        self.add_calls.append({
            "inference_state": inference_state,
            "frame_idx": frame_idx,
            "obj_id": obj_id,
            "mask": np.asarray(mask).copy(),
        })
        logits = np.where(np.asarray(mask), 3.0, -3.0)[None, None]
        return frame_idx, [obj_id], logits

    def propagate_in_video(self, **kwargs):
        print("predictor propagate diagnostic")
        self.propagate_calls.append(dict(kwargs))
        if self.crash:
            if self.mutate_before_crash:
                kwargs["inference_state"]["mutated_before_crash"] = True
            raise RuntimeError("predictor exploded")
        count = kwargs["max_frame_num_to_track"]
        indices = self.output_frames if self.output_frames is not None else list(range(count + 1))
        for position, local_index in enumerate(indices):
            logits = np.full((1, 1, HEIGHT, WIDTH), -4.0, np.float32)
            x0 = min(local_index + 1, WIDTH - 3)
            logits[0, 0, 2:7, x0:x0 + 3] = 4.0
            object_ids = [self.output_object_id]
            if self.tensor_like_output:
                object_ids = TensorLike(np.asarray(object_ids))
                logits = TensorLike(logits)
            yield local_index, object_ids, logits
            if position == 0 and self.after_first_output is not None:
                self.after_first_output()

    def reset_state(self, inference_state):
        print("predictor reset diagnostic")
        self.reset_calls.append(inference_state)

    def close(self):
        self.closed += 1


class TensorLike:
    """Torch-shaped external boundary double that only permits CPU conversion."""

    def __init__(self, value) -> None:
        self.value = np.asarray(value)

    def detach(self):
        return self

    def to(self, device: str):
        assert device == "cpu"
        return self

    def numpy(self):
        return self.value

    def __array__(self, *args, **kwargs):
        raise TypeError("direct NumPy conversion is forbidden for this tensor")


def _backend(tmp_path: Path, predictor: FakeVideoPredictor | None = None):
    tmp_path.mkdir(parents=True, exist_ok=True)
    chosen = predictor or FakeVideoPredictor()
    calls = []

    def factory(config: str, checkpoint: str, device: str):
        calls.append((config, checkpoint, device))
        return chosen

    checkpoint = tmp_path / "weights.pt"
    checkpoint.write_bytes(b"video-checkpoint")
    backend = SamVideoBackend(
        tmp_path,
        config_path="config.yaml",
        checkpoint_path=str(checkpoint),
        device="cpu",
        predictor_factory=factory,
    )
    return backend, chosen, calls


def _ready_backend(tmp_path: Path, count: int = 1, predictor=None):
    backend, chosen, calls = _backend(tmp_path, predictor)
    frames = _frames(tmp_path, count)
    backend.open_batch(frames)
    descriptor, mask = _mask(tmp_path)
    backend.add_mask(descriptor, 1)
    return backend, chosen, calls, frames, mask


def test_hello_loads_once_and_reports_backend_device_and_checkpoint_hash(tmp_path: Path) -> None:
    backend, predictor, calls = _backend(tmp_path)
    expected = hashlib.sha256(b"video-checkpoint").hexdigest()

    assert backend.hello() == {
        "backend": "sam2-video-predictor",
        "persistent": True,
        "device": "cpu",
        "checkpoint_sha256": expected,
    }
    assert backend.hello()["checkpoint_sha256"] == expected
    assert calls == [("config.yaml", str(tmp_path / "weights.pt"), "cpu")]
    assert predictor.init_calls == []


def test_open_batch_validates_all_frozen_pngs_before_one_new_state(tmp_path: Path) -> None:
    backend, predictor, _ = _backend(tmp_path)
    frames = _frames(tmp_path, 2)
    backend.open_batch(frames)

    assert len(predictor.init_calls) == 1
    runtime = Path(predictor.init_calls[0])
    assert runtime.parent.name == "runtime"
    assert predictor.loader_names == ["000000.jpg", "000001.jpg", "000002.jpg"]
    assert [path.name for path in sorted(runtime.iterdir())] == predictor.loader_names
    for index, path in enumerate(sorted(runtime.iterdir())):
        image = cv2.imread(str(path), cv2.IMREAD_COLOR)
        assert image is not None and image.shape[:2] == (HEIGHT, WIDTH)
        frozen = tmp_path / frames[index]["path"]
        assert frozen.suffix == ".png"
        assert hashlib.sha256(frozen.read_bytes()).hexdigest() == frames[index]["sha256"]


@pytest.mark.parametrize("kind", ["missing", "linked", "swapped", "dimensions"])
def test_open_batch_rejects_untrusted_frozen_png_before_init(tmp_path: Path, kind: str) -> None:
    backend, predictor, _ = _backend(tmp_path)
    frames = _frames(tmp_path, 1)
    second = tmp_path / frames[1]["path"]
    if kind == "missing":
        second.unlink()
    elif kind == "linked":
        target = tmp_path / "other.png"
        _write_png(target, np.zeros((HEIGHT, WIDTH, 3), np.uint8))
        second.unlink()
        second.symlink_to(target)
    elif kind == "swapped":
        _write_png(second, np.full((HEIGHT, WIDTH, 3), 99, np.uint8))
    else:
        frames[1]["width"] += 1

    with pytest.raises(ValueError):
        backend.open_batch(frames)
    assert predictor.init_calls == []


def test_second_open_batch_resets_old_state_and_creates_a_fresh_state(tmp_path: Path) -> None:
    backend, predictor, _ = _backend(tmp_path)
    frames = _frames(tmp_path, 1)
    first = backend.open_batch(frames)
    second = backend.open_batch(frames)

    assert first["batch_serial"] == 1 and second["batch_serial"] == 2
    assert len(predictor.init_calls) == 2
    assert predictor.init_calls[0] != predictor.init_calls[1]
    assert len(predictor.reset_calls) == 1
    assert predictor.reset_calls[0]["serial"] == 1


def test_invalid_replacement_batch_releases_the_previous_inference_state(
    tmp_path: Path,
) -> None:
    backend, predictor, _, _, _ = _ready_backend(tmp_path)
    replacement = _frames(tmp_path, 1)
    replacement[1]["sha256"] = "0" * 64

    with pytest.raises(ValueError, match="digest"):
        backend.open_batch(replacement)

    assert len(predictor.reset_calls) == 1
    with pytest.raises(RuntimeError, match="open_batch"):
        backend.propagate(1, 1)


def test_add_mask_accepts_one_full_image_binary_mask_at_keyframe(tmp_path: Path) -> None:
    backend, predictor, _, _, expected = _ready_backend(tmp_path)

    call = predictor.add_calls[-1]
    assert call["frame_idx"] == 0 and call["obj_id"] == 1
    assert call["inference_state"]["serial"] == 1
    assert call["mask"].dtype == np.bool_
    np.testing.assert_array_equal(call["mask"], expected > 0)


@pytest.mark.parametrize("kind", ["roi", "nonbinary", "wrong_object"])
def test_add_mask_rejects_non_full_binary_or_wrong_object(tmp_path: Path, kind: str) -> None:
    backend, predictor, _ = _backend(tmp_path)
    backend.open_batch(_frames(tmp_path, 1))
    descriptor, _ = _mask(tmp_path)
    object_id = 1
    if kind == "roi":
        descriptor["roi"] = [1, 0, WIDTH - 1, HEIGHT]
    elif kind == "nonbinary":
        invalid = np.zeros((HEIGHT, WIDTH), np.uint8)
        invalid[0, 0] = 17
        descriptor["sha256"] = _write_png(tmp_path / descriptor["path"], invalid)
    else:
        object_id = 2

    with pytest.raises(ValueError):
        backend.add_mask(descriptor, object_id)
    assert predictor.add_calls == []


@pytest.mark.parametrize("count", [1, 5, 30])
def test_propagate_forwards_exact_bounds_and_returns_only_target_masks(
    tmp_path: Path, count: int
) -> None:
    backend, predictor, _, frames, _ = _ready_backend(tmp_path, count)
    result = backend.propagate(count, 1)

    call = predictor.propagate_calls[-1]
    assert call["reverse"] is False
    assert call["start_frame_idx"] == 0
    assert call["max_frame_num_to_track"] == count
    assert [item["local_index"] for item in result["masks"]] == list(range(1, count + 1))
    assert len(result["masks"]) == count
    for local_index, descriptor in enumerate(result["masks"], start=1):
        assert descriptor["playback_index"] == frames[local_index]["playback_index"]
        assert descriptor["frame_id"] == frames[local_index]["frame_id"]
        assert descriptor["object_id"] == 1
        assert np.isfinite(descriptor["score"])
        path = tmp_path / descriptor["path"]
        assert path.parent.name == "outputs" and path.is_file() and not path.is_symlink()
        assert hashlib.sha256(path.read_bytes()).hexdigest() == descriptor["sha256"]
        crop = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
        assert crop is not None and set(np.unique(crop)).issubset({0, 255})
        assert [crop.shape[1], crop.shape[0]] == descriptor["roi"][2:]


def test_propagate_converts_external_tensor_outputs_to_cpu_without_importing_torch(
    tmp_path: Path,
) -> None:
    predictor = FakeVideoPredictor()
    predictor.tensor_like_output = True
    backend, _, _, _, _ = _ready_backend(tmp_path, 1, predictor)

    result = backend.propagate(1, 1)

    assert len(result["masks"]) == 1
    assert result["masks"][0]["local_index"] == 1


@pytest.mark.parametrize(
    "mode", ["crash", "short", "long", "wrong_object", "noninteger_object"]
)
def test_propagate_rejects_crash_count_mismatch_and_wrong_output_object(
    tmp_path: Path, mode: str
) -> None:
    predictor = FakeVideoPredictor()
    if mode == "crash":
        predictor.crash = True
    elif mode == "short":
        predictor.output_frames = [0]
    elif mode == "long":
        predictor.output_frames = [0, 1, 2]
    elif mode == "wrong_object":
        predictor.output_object_id = 2
    else:
        predictor.output_object_id = 1.0
    backend, _, _, _, _ = _ready_backend(tmp_path, 1, predictor)

    with pytest.raises((RuntimeError, ValueError)):
        backend.propagate(1, 1)


def test_cancel_reset_and_late_output_invalidate_propagation(tmp_path: Path) -> None:
    backend, _, _, _, _ = _ready_backend(tmp_path / "cancel")
    assert backend.cancel("propagate-r1") == {
        "target_request_id": "propagate-r1", "cancelled": True
    }
    with pytest.raises(RuntimeError, match="cancel"):
        backend.propagate(1, 1)

    backend, _, _, _, _ = _ready_backend(tmp_path / "reset")
    backend.reset_batch()
    with pytest.raises(RuntimeError, match="batch"):
        backend.propagate(1, 1)

    predictor = FakeVideoPredictor()
    backend, _, _, _, _ = _ready_backend(tmp_path / "late", predictor=predictor)
    predictor.after_first_output = backend.reset_batch
    with pytest.raises(RuntimeError, match="stale|reset"):
        backend.propagate(1, 1)


def test_predictor_crash_releases_even_mutated_state_and_requires_new_batch(
    tmp_path: Path,
) -> None:
    predictor = FakeVideoPredictor()
    predictor.crash = True
    predictor.mutate_before_crash = True
    backend, _, calls, _, _ = _ready_backend(tmp_path, 1, predictor)

    with pytest.raises(RuntimeError, match="exploded"):
        backend.propagate(1, 1)

    assert len(predictor.reset_calls) == 1
    assert predictor.reset_calls[0]["mutated_before_crash"] is True
    with pytest.raises(RuntimeError, match="open_batch"):
        backend.propagate(1, 1)

    predictor.crash = False
    backend.open_batch(_frames(tmp_path, 1))
    assert len(calls) == 1


def test_key_mask_hash_failure_releases_state_and_prevents_reuse(tmp_path: Path) -> None:
    backend, predictor, _ = _backend(tmp_path)
    backend.open_batch(_frames(tmp_path, 1))
    descriptor, _ = _mask(tmp_path)
    wrong = {**descriptor, "sha256": "0" * 64}

    with pytest.raises(ValueError, match="digest"):
        backend.add_mask(wrong, 1)

    assert len(predictor.reset_calls) == 1
    with pytest.raises(RuntimeError, match="open_batch"):
        backend.add_mask(descriptor, 1)


@pytest.mark.parametrize(
    "kind",
    [
        "frozen_swapped", "runtime_missing", "runtime_linked",
        "runtime_swapped", "runtime_dimensions", "runtime_extra",
    ],
)
def test_active_batch_rejects_changed_or_extra_authoritative_inputs(
    tmp_path: Path, kind: str
) -> None:
    backend, predictor, _ = _backend(tmp_path)
    frames = _frames(tmp_path, 1)
    backend.open_batch(frames)
    runtime = Path(predictor.init_calls[-1])
    runtime_target = runtime / "000001.jpg"
    if kind == "frozen_swapped":
        _write_png(tmp_path / frames[1]["path"], np.full((HEIGHT, WIDTH, 3), 77, np.uint8))
    elif kind == "runtime_missing":
        runtime_target.unlink()
    elif kind == "runtime_linked":
        runtime_target.unlink()
        runtime_target.symlink_to(tmp_path / frames[1]["path"])
    elif kind == "runtime_swapped":
        _write_png(runtime_target, np.full((HEIGHT, WIDTH, 3), 77, np.uint8))
    elif kind == "runtime_dimensions":
        _write_png(runtime_target, np.zeros((HEIGHT, WIDTH + 1, 3), np.uint8))
    else:
        _write_png(runtime / "extra.png", np.zeros((HEIGHT, WIDTH, 3), np.uint8))
    descriptor, _ = _mask(tmp_path)

    with pytest.raises(ValueError):
        backend.add_mask(descriptor, 1)


def test_reset_retains_model_and_shutdown_releases_state_once(tmp_path: Path) -> None:
    backend, predictor, calls = _backend(tmp_path)
    backend.open_batch(_frames(tmp_path, 1))
    backend.reset_batch()
    backend.open_batch(_frames(tmp_path, 1))
    assert len(calls) == 1
    backend.shutdown()
    backend.shutdown()
    assert len(predictor.reset_calls) == 2
    assert predictor.closed == 1


def test_official_factory_uses_only_an_installed_absolute_config_and_device_semantics(
    tmp_path: Path, monkeypatch
) -> None:
    package_root = tmp_path / "site-packages" / "sam2"
    config = package_root / "configs" / "sam2.1" / "tiny.yaml"
    config.parent.mkdir(parents=True)
    config.write_text("model: {}\n", encoding="utf-8")
    checkpoint = tmp_path / "tiny.pt"
    checkpoint.write_bytes(b"checkpoint")
    built = []
    predictor = FakeVideoPredictor()

    fake_torch = types.ModuleType("torch")
    fake_torch.cuda = types.SimpleNamespace(is_available=lambda: False)
    fake_sam2 = types.ModuleType("sam2")
    fake_sam2.__path__ = [str(package_root)]
    fake_build = types.ModuleType("sam2.build_sam")

    def build(config_name, checkpoint_name, *, device):
        built.append((config_name, checkpoint_name, device))
        return predictor

    fake_build.build_sam2_video_predictor = build
    monkeypatch.setitem(sys.modules, "torch", fake_torch)
    monkeypatch.setitem(sys.modules, "sam2", fake_sam2)
    monkeypatch.setitem(sys.modules, "sam2.build_sam", fake_build)

    returned = SamVideoBackend._official_predictor(
        str(config.resolve()), str(checkpoint.resolve()), "auto"
    )
    assert returned is predictor
    assert built == [("configs/sam2.1/tiny.yaml", str(checkpoint.resolve()), "cpu")]
    assert predictor.sam_video_device == "cpu"
    with pytest.raises(RuntimeError, match="CUDA"):
        SamVideoBackend._official_predictor(
            str(config.resolve()), str(checkpoint.resolve()), "cuda"
        )
    outside = tmp_path / "outside.yaml"
    outside.write_text("model: {}\n", encoding="utf-8")
    with pytest.raises(RuntimeError, match="installed sam2"):
        SamVideoBackend._official_predictor(
            str(outside.resolve()), str(checkpoint.resolve()), "cpu"
        )
