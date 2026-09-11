"""Persistent worker tests using the real backend and an external predictor seam."""
from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path

import cv2
import numpy as np
import pytest

from annotation_data.sam_video_backend import SamVideoBackend
from sam_video_worker import run_loop


WIDTH = 16
HEIGHT = 12
SESSION_ID = "worker-session"


def _write_png(path: Path, image: np.ndarray) -> str:
    ok, encoded = cv2.imencode(".png", image)
    assert ok
    payload = encoded.tobytes()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    return hashlib.sha256(payload).hexdigest()


def _context() -> dict:
    return {
        "session_id": SESSION_ID,
        "request_nonce": "nonce-a",
        "key_playback_index": 4,
        "key_frame_id": 11825,
        "key_time_s": 473.0,
        "targets": [{
            "playback_index": 5,
            "frame_id": 11850,
            "time_s": 474.0,
            "entry_sha256": "a" * 64,
            "image_sha256": "b" * 64,
        }],
        "store_revision": 7,
        "review_sha256": "c" * 64,
        "key_record_sha256": "d" * 64,
        "region_id": "instrument-1",
        "propagation_count": 1,
        "requested_device": "cpu",
    }


def _request(
    request_id: str,
    op: str,
    data: dict | None = None,
    *,
    context: dict | None = None,
) -> dict:
    return {
        "protocol": "sam-video-v1",
        "request_id": request_id,
        "op": op,
        "context": _context() if context is None else context,
        "data": {} if data is None else data,
    }


def _frozen_inputs(root: Path) -> tuple[list[dict], dict]:
    frames = []
    for local_index in range(2):
        relative = f"frozen/{local_index}.png"
        digest = _write_png(
            root / relative,
            np.full((HEIGHT, WIDTH, 3), local_index * 20, np.uint8),
        )
        frames.append({
            "path": relative,
            "sha256": digest,
            "width": WIDTH,
            "height": HEIGHT,
            "playback_index": 4 + local_index,
            "frame_id": 11825 + local_index * 25,
        })
    mask = np.zeros((HEIGHT, WIDTH), np.uint8)
    mask[2:8, 3:11] = 255
    mask_path = "frozen/key-mask.png"
    mask_digest = _write_png(root / mask_path, mask)
    return frames, {
        "path": mask_path,
        "sha256": mask_digest,
        "roi": [0, 0, WIDTH, HEIGHT],
    }


class FakeVideoPredictor:
    """The only double: the official four-method SAM video predictor seam."""

    sam_video_device = "cpu"

    def __init__(self) -> None:
        self.init_calls: list[str] = []
        self.add_calls: list[dict] = []
        self.propagate_calls: list[dict] = []
        self.reset_calls: list[dict] = []
        self.closed = 0
        self.fail_propagate = False

    def init_state(self, *, video_path: str):
        print("predictor diagnostic: init")
        names = [
            name for name in os.listdir(video_path)
            if Path(name).suffix in {".jpg", ".jpeg", ".JPG", ".JPEG"}
        ]
        names.sort(key=lambda name: int(Path(name).stem))
        if names != ["000000.jpg", "000001.jpg"]:
            raise RuntimeError("official loader filename contract rejected runtime")
        state = {"serial": len(self.init_calls) + 1, "video_path": video_path}
        self.init_calls.append(video_path)
        return state

    def add_new_mask(self, *, inference_state, frame_idx: int, obj_id: int, mask):
        print("predictor diagnostic: add")
        self.add_calls.append({
            "state": inference_state,
            "frame_idx": frame_idx,
            "obj_id": obj_id,
            "mask": np.asarray(mask).copy(),
        })
        return frame_idx, [obj_id], np.asarray(mask, np.float32)[None, None]

    def propagate_in_video(self, **kwargs):
        print("predictor diagnostic: propagate")
        self.propagate_calls.append(dict(kwargs))
        if self.fail_propagate:
            kwargs["inference_state"]["mutated_before_crash"] = True
            raise RuntimeError("predictor crashed after mutation")
        for local_index in (0, 1):
            logits = np.full((1, 1, HEIGHT, WIDTH), -3.0, np.float32)
            logits[0, 0, 2:7, 3 + local_index:8 + local_index] = 3.0
            yield local_index, [1], logits

    def reset_state(self, inference_state):
        print("predictor diagnostic: reset")
        self.reset_calls.append(inference_state)

    def close(self):
        print("predictor diagnostic: close")
        self.closed += 1


def _backend(tmp_path: Path, predictor: FakeVideoPredictor | None = None):
    chosen = predictor or FakeVideoPredictor()
    checkpoint = tmp_path / "weights.pt"
    checkpoint.write_bytes(b"worker-checkpoint")
    factory_calls = []

    def factory(config: str, checkpoint_path: str, device: str):
        factory_calls.append((config, checkpoint_path, device))
        return chosen

    backend = SamVideoBackend(
        tmp_path,
        config_path="config.yaml",
        checkpoint_path=str(checkpoint),
        device="cpu",
        predictor_factory=factory,
    )
    return backend, chosen, factory_calls


def _encode_requests(requests: list[dict]) -> bytes:
    return b"".join(
        (json.dumps(item, separators=(",", ":")) + "\n").encode()
        for item in requests
    )


def _run(backend: SamVideoBackend, raw: bytes, *, session_id: str = SESSION_ID):
    source = io.BytesIO(raw)
    output = io.BytesIO()
    assert run_loop(backend, source, output, service_session_id=session_id) == 0
    return [json.loads(line) for line in output.getvalue().splitlines()]


def test_real_backend_loop_dispatches_every_op_and_keeps_stdout_jsonl_only(
    tmp_path: Path, capsys
) -> None:
    frames, mask = _frozen_inputs(tmp_path)
    backend, predictor, factory_calls = _backend(tmp_path)
    requests = [
        _request("r1", "hello"),
        _request("r2", "open_batch", {"frames": frames}),
        _request("r3", "add_mask", {"mask": mask, "object_id": 1}),
        _request("r4", "propagate", {"count": 1, "object_id": 1}),
        _request("r5", "cancel", {"target_request_id": "r4"}),
        _request("r6", "reset_batch"),
        _request("r7", "shutdown"),
    ]

    responses = _run(backend, _encode_requests(requests))

    assert [item["request_id"] for item in responses] == [f"r{i}" for i in range(1, 8)]
    assert all(set(item) == {
        "protocol", "request_id", "ok", "context", "data", "errors"
    } for item in responses)
    assert all(item["ok"] for item in responses)
    assert responses[0]["data"]["session_id"] == SESSION_ID
    assert isinstance(responses[0]["data"]["pid"], int)
    output_descriptor = responses[3]["data"]["masks"][0]
    assert output_descriptor["frame_id"] == 11850
    assert (tmp_path / output_descriptor["path"]).is_file()
    assert len(factory_calls) == 1
    assert len(predictor.init_calls) == 1
    assert len(predictor.add_calls) == 1
    assert len(predictor.propagate_calls) == 1
    assert predictor.reset_calls
    assert predictor.closed == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "predictor diagnostic" in captured.err


@pytest.mark.parametrize(
    "kind",
    [
        "region", "nonce", "revision", "target", "key_time_missing",
        "target_time", "session", "device",
    ],
)
def test_context_mismatch_rejects_request_and_invalidates_bound_batch(
    tmp_path: Path, kind: str
) -> None:
    frames, mask = _frozen_inputs(tmp_path)
    backend, predictor, _ = _backend(tmp_path)
    changed = _context()
    if kind == "region":
        changed["region_id"] = "instrument-2"
    elif kind == "nonce":
        changed["request_nonce"] = "nonce-b"
    elif kind == "revision":
        changed["store_revision"] += 1
    elif kind == "target":
        changed["targets"][0]["entry_sha256"] = "f" * 64
    elif kind == "key_time_missing":
        del changed["key_time_s"]
    elif kind == "target_time":
        changed["targets"][0]["time_s"] = 474.5
    elif kind == "session":
        changed["session_id"] = "other-session"
    else:
        changed["requested_device"] = "cuda"
    requests = [
        _request("r1", "hello"),
        _request("r2", "open_batch", {"frames": frames}),
        _request("r3", "add_mask", {"mask": mask, "object_id": 1}, context=changed),
        _request("r4", "add_mask", {"mask": mask, "object_id": 1}),
    ]

    responses = _run(backend, _encode_requests(requests))

    assert [item["ok"] for item in responses] == [True, True, False, False]
    error = responses[2]["errors"][0].lower()
    assert "context" in error or "session" in error or "device" in error
    assert "open_batch" in responses[3]["errors"][0]
    assert len(predictor.reset_calls) == 1


@pytest.mark.parametrize("kind", ["session", "device"])
def test_configured_session_and_device_are_checked_before_hello_dispatch(
    tmp_path: Path, kind: str
) -> None:
    backend, predictor, factory_calls = _backend(tmp_path)
    changed = _context()
    if kind == "session":
        changed["session_id"] = "other-session"
    else:
        changed["requested_device"] = "cuda"

    responses = _run(
        backend,
        _encode_requests([_request("r1", "hello", context=changed)]),
    )

    assert len(responses) == 1 and responses[0]["ok"] is False
    assert factory_calls == []
    assert predictor.closed == 0


def test_malformed_request_invalidates_active_batch_before_continuing(tmp_path: Path) -> None:
    frames, mask = _frozen_inputs(tmp_path)
    backend, predictor, _ = _backend(tmp_path)
    malformed = (
        b'{"protocol":"sam-video-v1","request_id":"bad-1",'
        b'"request_id":"bad-2","op":"hello","context":{},"data":{}}\n'
    )
    raw = _encode_requests([
        _request("r1", "hello"),
        _request("r2", "open_batch", {"frames": frames}),
    ]) + malformed + _encode_requests([
        _request("r3", "add_mask", {"mask": mask, "object_id": 1}),
    ])

    responses = _run(backend, raw)

    assert [item["ok"] for item in responses] == [True, True, False, False]
    assert responses[2]["request_id"] == "bad-1"
    assert "duplicate" in responses[2]["errors"][0]
    assert "open_batch" in responses[3]["errors"][0]
    assert len(predictor.reset_calls) == 1


def test_hash_failure_and_predictor_crash_each_prevent_state_reuse(tmp_path: Path) -> None:
    frames, mask = _frozen_inputs(tmp_path)
    backend, predictor, _ = _backend(tmp_path)
    wrong_mask = {**mask, "sha256": "0" * 64}
    responses = _run(backend, _encode_requests([
        _request("r1", "hello"),
        _request("r2", "open_batch", {"frames": frames}),
        _request("r3", "add_mask", {"mask": wrong_mask, "object_id": 1}),
        _request("r4", "add_mask", {"mask": mask, "object_id": 1}),
    ]))
    assert [item["ok"] for item in responses] == [True, True, False, False]
    assert "open_batch" in responses[3]["errors"][0]
    assert len(predictor.reset_calls) == 1

    crash_root = tmp_path / "crash"
    crash_root.mkdir()
    frames, mask = _frozen_inputs(crash_root)
    predictor = FakeVideoPredictor()
    predictor.fail_propagate = True
    backend, predictor, _ = _backend(crash_root, predictor)
    responses = _run(backend, _encode_requests([
        _request("r1", "hello"),
        _request("r2", "open_batch", {"frames": frames}),
        _request("r3", "add_mask", {"mask": mask, "object_id": 1}),
        _request("r4", "propagate", {"count": 1, "object_id": 1}),
        _request("r5", "propagate", {"count": 1, "object_id": 1}),
    ]))
    assert [item["ok"] for item in responses] == [True, True, True, False, False]
    assert predictor.reset_calls[0]["mutated_before_crash"] is True
    assert "open_batch" in responses[4]["errors"][0]


def test_overlong_physical_line_is_drained_and_gets_exactly_one_response(
    tmp_path: Path,
) -> None:
    backend, _, _ = _backend(tmp_path)
    oversized = (
        b'{"protocol":"sam-video-v1","request_id":"r-long","padding":"'
        + b"x" * 1_048_576
        + b'"}\n'
    )
    following = _encode_requests([_request("r-next", "reset_batch")])

    responses = _run(backend, oversized + following)

    assert [item["request_id"] for item in responses] == ["r-long", "r-next"]
    assert responses[0]["ok"] is False and responses[1]["ok"] is True


def test_clean_eof_releases_real_backend_state(tmp_path: Path) -> None:
    frames, _ = _frozen_inputs(tmp_path)
    backend, predictor, _ = _backend(tmp_path)

    responses = _run(backend, _encode_requests([
        _request("r1", "hello"),
        _request("r2", "open_batch", {"frames": frames}),
    ]))

    assert [item["ok"] for item in responses] == [True, True]
    assert len(predictor.reset_calls) == 1
    assert predictor.closed == 1
