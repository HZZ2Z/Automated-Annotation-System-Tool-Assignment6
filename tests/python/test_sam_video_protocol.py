"""Literal contract tests for the ``sam-video-v1`` JSONL protocol."""
from __future__ import annotations

from copy import deepcopy
import json

import pytest

from annotation_data.sam_video_protocol import (
    MAX_LINE_BYTES,
    error_response,
    loads_line,
    success_response,
    validate_request,
)


def context() -> dict:
    return {
        "session_id": "session-a",
        "request_nonce": "nonce-a",
        "key_playback_index": 4,
        "key_frame_id": 11825,
        "key_time_s": 473.0,
        "targets": [
            {
                "playback_index": 5,
                "frame_id": 11850,
                "time_s": 474.0,
                "entry_sha256": "a" * 64,
                "image_sha256": "b" * 64,
            }
        ],
        "store_revision": 7,
        "review_sha256": "c" * 64,
        "key_record_sha256": "d" * 64,
        "region_id": "instrument-1",
        "propagation_count": 1,
        "requested_device": "cpu",
    }


def frame(
    name: str,
    playback_index: int,
    frame_id: int,
    *,
    digest: str = "e" * 64,
) -> dict:
    return {
        "path": name,
        "sha256": digest,
        "width": 854,
        "height": 480,
        "playback_index": playback_index,
        "frame_id": frame_id,
    }


def request(op: str, *, ctx: dict | None = None, data: dict | None = None) -> dict:
    return {
        "protocol": "sam-video-v1",
        "request_id": "r1",
        "op": op,
        "context": context() if ctx is None else ctx,
        "data": {} if data is None else data,
    }


def open_batch_data() -> dict:
    return {
        "frames": [
            frame("frames/000000.png", 4, 11825),
            frame("frames/000001.png", 5, 11850, digest="f" * 64),
        ]
    }


def mask_descriptor() -> dict:
    return {
        "path": "masks/key.png",
        "sha256": "9" * 64,
        "roi": [0, 0, 854, 480],
    }


@pytest.mark.parametrize(
    ("op", "data"),
    [
        ("hello", {}),
        ("open_batch", open_batch_data()),
        ("add_mask", {"mask": mask_descriptor(), "object_id": 1}),
        ("propagate", {"count": 1, "object_id": 1}),
        ("cancel", {"target_request_id": "r0"}),
        ("reset_batch", {}),
        ("shutdown", {}),
    ],
)
def test_every_operation_has_one_exact_normalized_shape(op: str, data: dict) -> None:
    value = request(op, data=deepcopy(data))
    normalized = validate_request(value)

    value["context"]["targets"][0]["frame_id"] = 99999
    value["data"]["mutated_after_validation"] = True
    if isinstance(data.get("frames"), list):
        value["data"]["frames"][0]["frame_id"] = 99999

    assert normalized == request(op, data=data)


def test_optional_source_times_preserve_presence_and_exact_numeric_value() -> None:
    with_times = validate_request(request("hello"))["context"]
    without = context()
    del without["key_time_s"]
    del without["targets"][0]["time_s"]
    without_times = validate_request(request("hello", ctx=without))["context"]

    assert with_times["key_time_s"] == 473.0
    assert with_times["targets"][0]["time_s"] == 474.0
    assert "key_time_s" not in without_times
    assert "time_s" not in without_times["targets"][0]


@pytest.mark.parametrize(
    "raw",
    [
        b'{"protocol":"sam-video-v1","request_id":"r1","request_id":"r2","op":"hello","context":{},"data":{}}\n',
        b'{"protocol":"sam-video-v1","request_id":"r1","op":"hello","context":{},"data":{"score":NaN}}\n',
        b'{"protocol":"sam-video-v1","request_id":"r1","op":"hello","context":{},"data":{"score":Infinity}}\n',
        b'{"protocol":"sam-video-v1","request_id":"r1","op":"hello","context":{},"data":{}} trailing\n',
        b"\xff\n",
    ],
)
def test_loader_rejects_duplicate_nonfinite_or_malformed_json(raw: bytes) -> None:
    with pytest.raises(ValueError):
        loads_line(raw)


def test_loader_rejects_a_line_over_one_mib_and_embedded_lines() -> None:
    valid = json.dumps(request("hello"), separators=(",", ":")).encode()
    with pytest.raises(ValueError, match="line"):
        loads_line(valid + b" " * (MAX_LINE_BYTES - len(valid)) + b"\n")
    with pytest.raises(ValueError, match="line"):
        loads_line(valid + b"\n" + valid + b"\n")


@pytest.mark.parametrize(
    "mutation",
    [
        lambda value: value.update(extra=True),
        lambda value: value.pop("data"),
        lambda value: value.update(protocol="wrong-v1"),
        lambda value: value.update(op="unknown"),
        lambda value: value.update(request_id="bad\nrequest"),
        lambda value: value.update(context=[]),
        lambda value: value.update(data=[]),
    ],
)
def test_request_rejects_extra_missing_unknown_and_bad_envelope_fields(mutation) -> None:
    value = request("hello")
    mutation(value)
    with pytest.raises(ValueError):
        validate_request(value)


@pytest.mark.parametrize(
    ("field", "bad"),
    [
        ("key_playback_index", True),
        ("key_frame_id", True),
        ("key_time_s", float("nan")),
        ("store_revision", True),
        ("propagation_count", True),
        ("propagation_count", 0),
        ("propagation_count", 31),
        ("review_sha256", "C" * 64),
        ("key_record_sha256", "g" * 64),
        ("region_id", "bad\x00region"),
        ("requested_device", "tpu"),
    ],
)
def test_context_rejects_bool_as_int_nonfinite_bounds_digests_and_controls(
    field: str, bad: object
) -> None:
    ctx = context()
    ctx[field] = bad
    with pytest.raises(ValueError):
        validate_request(request("hello", ctx=ctx))


@pytest.mark.parametrize("kind", ["missing", "extra"])
def test_context_rejects_missing_or_extra_fields(kind: str) -> None:
    ctx = context()
    if kind == "missing":
        del ctx["region_id"]
    else:
        ctx["extra"] = 1
    with pytest.raises(ValueError):
        validate_request(request("hello", ctx=ctx))


@pytest.mark.parametrize(
    "targets",
    [
        [
            {"playback_index": 5, "frame_id": 11850, "entry_sha256": "a" * 64, "image_sha256": "b" * 64},
            {"playback_index": 5, "frame_id": 11851, "entry_sha256": "a" * 64, "image_sha256": "b" * 64},
        ],
        [
            {"playback_index": 6, "frame_id": 11851, "entry_sha256": "a" * 64, "image_sha256": "b" * 64},
            {"playback_index": 5, "frame_id": 11850, "entry_sha256": "a" * 64, "image_sha256": "b" * 64},
        ],
        [{"playback_index": 4, "frame_id": 11825, "entry_sha256": "a" * 64, "image_sha256": "b" * 64}],
    ],
)
def test_targets_reject_repeated_unsorted_or_nonforward_playback_indices(targets: list) -> None:
    ctx = context()
    ctx["targets"] = targets
    ctx["propagation_count"] = len(targets)
    with pytest.raises(ValueError):
        validate_request(request("hello", ctx=ctx))


def test_target_count_must_equal_context_propagation_count() -> None:
    ctx = context()
    ctx["propagation_count"] = 2
    with pytest.raises(ValueError, match="targets"):
        validate_request(request("hello", ctx=ctx))


@pytest.mark.parametrize(
    "bad",
    [
        {"playback_index": True, "frame_id": 11850, "entry_sha256": "a" * 64, "image_sha256": "b" * 64},
        {"playback_index": 5, "frame_id": True, "entry_sha256": "a" * 64, "image_sha256": "b" * 64},
        {"playback_index": 5, "frame_id": 11850, "time_s": float("inf"), "entry_sha256": "a" * 64, "image_sha256": "b" * 64},
        {"playback_index": 5, "frame_id": 11850, "entry_sha256": "A" * 64, "image_sha256": "b" * 64},
        {"playback_index": 5, "frame_id": 11850, "entry_sha256": "a" * 64, "image_sha256": "B" * 64},
        {"playback_index": 5, "frame_id": 11850, "entry_sha256": "a" * 64, "image_sha256": "b" * 64, "extra": 1},
    ],
)
def test_target_entries_reject_invalid_fields(bad: dict) -> None:
    ctx = context()
    ctx["targets"] = [bad]
    with pytest.raises(ValueError):
        validate_request(request("hello", ctx=ctx))


@pytest.mark.parametrize(
    "bad_frame",
    [
        frame("../outside.png", 4, 11825),
        frame("/tmp/input.png", 4, 11825),
        frame("frames/input.jpg", 4, 11825),
        frame("frames/input.png", True, 11825),
        frame("frames/input.png", 4, True),
        frame("frames/input.png", 4, 11825, digest="E" * 64),
        {**frame("frames/input.png", 4, 11825), "extra": 1},
    ],
)
def test_open_batch_rejects_untrusted_or_invalid_frame_descriptors(bad_frame: dict) -> None:
    data = open_batch_data()
    data["frames"][0] = bad_frame
    with pytest.raises(ValueError):
        validate_request(request("open_batch", data=data))


@pytest.mark.parametrize(
    "frames",
    [
        [frame("frames/000000.png", 4, 11825)],
        [
            frame("frames/000000.png", 4, 11825),
            frame("frames/000001.png", 6, 11850),
        ],
        [
            frame("frames/000000.png", 5, 11850),
            frame("frames/000001.png", 4, 11825),
        ],
    ],
)
def test_open_batch_requires_key_then_every_ordered_target(frames: list) -> None:
    with pytest.raises(ValueError):
        validate_request(request("open_batch", data={"frames": frames}))


@pytest.mark.parametrize(
    "data",
    [
        {"mask": mask_descriptor(), "object_id": 2},
        {"mask": mask_descriptor(), "object_id": True},
        {"mask": {**mask_descriptor(), "path": "../key.png"}, "object_id": 1},
        {"mask": {**mask_descriptor(), "sha256": "A" * 64}, "object_id": 1},
        {"mask": {**mask_descriptor(), "roi": [0, 0, 0, 480]}, "object_id": 1},
        {"mask": {**mask_descriptor(), "roi": [0, 0, 854, 480.0]}, "object_id": 1},
        {"mask": {**mask_descriptor(), "extra": 1}, "object_id": 1},
    ],
)
def test_add_mask_requires_object_one_and_exact_binary_mask_descriptor(data: dict) -> None:
    with pytest.raises(ValueError):
        validate_request(request("add_mask", data=data))


@pytest.mark.parametrize(
    "data",
    [
        {"count": 0, "object_id": 1},
        {"count": 31, "object_id": 1},
        {"count": True, "object_id": 1},
        {"count": 1, "object_id": 2},
        {"count": 1, "object_id": True},
        {"count": 1, "object_id": 1, "extra": 1},
    ],
)
def test_propagate_rejects_bad_count_object_or_fields(data: dict) -> None:
    with pytest.raises(ValueError):
        validate_request(request("propagate", data=data))


def test_propagate_count_must_match_context_and_empty_ops_reject_data() -> None:
    with pytest.raises(ValueError, match="context"):
        validate_request(request("propagate", data={"count": 2, "object_id": 1}))
    for op in ("hello", "reset_batch", "shutdown"):
        with pytest.raises(ValueError):
            validate_request(request(op, data={"extra": 1}))
    with pytest.raises(ValueError):
        validate_request(request("cancel", data={"target_request_id": ""}))


def test_response_builders_have_exact_shapes_and_defensive_copies() -> None:
    source = request("propagate", data={"count": 1, "object_id": 1})
    result = {"masks": [{"path": "outputs/000001.png"}]}
    response = success_response(source, result)
    source["context"]["targets"][0]["frame_id"] = 99999
    result["masks"][0]["path"] = "changed.png"

    assert response == {
        "protocol": "sam-video-v1",
        "request_id": "r1",
        "ok": True,
        "context": context(),
        "data": {"masks": [{"path": "outputs/000001.png"}]},
        "errors": [],
    }
    error_context = context()
    failure = error_response("r7", error_context, ["propagation failed"])
    error_context["targets"][0]["frame_id"] = 99999
    assert failure == {
        "protocol": "sam-video-v1",
        "request_id": "r7",
        "ok": False,
        "context": context(),
        "data": {},
        "errors": ["propagation failed"],
    }
    for errors in ([], [1], [""], "failed"):
        with pytest.raises(ValueError):
            error_response("r7", {}, errors)  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        success_response(request("hello"), {"score": float("nan")})
