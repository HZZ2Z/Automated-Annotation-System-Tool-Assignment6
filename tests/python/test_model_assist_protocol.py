"""Literal contract tests for the ``model-assist-v1`` JSONL protocol."""
from __future__ import annotations

import json

import pytest

from annotation_data.model_assist_protocol import (
    MAX_LINE_BYTES,
    error_response,
    loads_line,
    success_response,
    validate_request,
)


def context(*, prompt_revision: int = 0) -> dict:
    return {
        "session_id": "session-1",
        "frame_id": 49,
        "playback_index": 7,
        "image_sha256": "a" * 64,
        "record_sha256": "b" * 64,
        "selected_region_id": "frame-49-polygon-2",
        "prompt_revision": prompt_revision,
    }


def descriptor(name: str = "input.png") -> dict:
    return {"path": name, "sha256": "c" * 64, "width": 854, "height": 480}


def request(op: str, *, ctx: dict | None = None, data: dict | None = None) -> dict:
    return {
        "protocol": "model-assist-v1",
        "request_id": "r1",
        "op": op,
        "context": {} if ctx is None else ctx,
        "data": {} if data is None else data,
    }


def predict_data(**changes: object) -> dict:
    value = {
        "points": [[20.0, 30.0]],
        "labels": [1],
        "box": None,
        "initial_mask": None,
    }
    value.update(changes)
    return value


def test_canonical_predict_request_is_normalized_without_file_access():
    parsed = loads_line((json.dumps(request(
        "predict", ctx=context(prompt_revision=3), data=predict_data()
    )) + "\n").encode())

    assert parsed["context"]["prompt_revision"] == 3
    assert parsed["data"] == predict_data()


@pytest.mark.parametrize("op,data", [
    ("hello", {}),
    ("set_image", {"image": descriptor()}),
    ("cancel", {"target_request_id": "r4"}),
    ("shutdown", {}),
])
def test_supported_operations_have_exact_shapes(op: str, data: dict):
    ctx = context() if op == "set_image" else {}
    assert validate_request(request(op, ctx=ctx, data=data))["op"] == op


@pytest.mark.parametrize("mutation", [
    lambda value: value.update(extra=True),
    lambda value: value.update(protocol="wrong-protocol-v1"),
    lambda value: value.update(op="unknown"),
    lambda value: value.update(request_id=""),
    lambda value: value.update(request_id=1),
    lambda value: value.update(context=[]),
    lambda value: value.update(data=[]),
])
def test_request_rejects_unknown_fields_protocol_ops_and_bad_envelopes(mutation):
    value = request("hello")
    mutation(value)
    with pytest.raises(ValueError):
        validate_request(value)


@pytest.mark.parametrize("raw", [
    b'{"protocol":"model-assist-v1","request_id":"r1","request_id":"r2","op":"hello","context":{},"data":{}}\n',
    b'{"protocol":"model-assist-v1","request_id":"r1","op":"hello","context":{},"data":{"score":NaN}}\n',
    b'{"protocol":"model-assist-v1","request_id":"r1","op":"hello","context":{},"data":{"score":Infinity}}\n',
    b'{"protocol":"model-assist-v1","request_id":"r1","op":"hello","context":{},"data":{}} trailing\n',
    b'\xff\n',
])
def test_line_loader_rejects_duplicate_nonfinite_or_malformed_json(raw: bytes):
    with pytest.raises(ValueError):
        loads_line(raw)


def test_line_loader_rejects_more_than_one_mib_and_embedded_lines():
    valid = b'{"protocol":"model-assist-v1","request_id":"r1","op":"hello","context":{},"data":{}}'
    with pytest.raises(ValueError, match="line"):
        loads_line(valid + b" " * (MAX_LINE_BYTES - len(valid)) + b"\n")
    with pytest.raises(ValueError, match="line"):
        loads_line(valid + b"\n" + valid + b"\n")


@pytest.mark.parametrize("field,value", [
    ("frame_id", -1),
    ("frame_id", True),
    ("playback_index", -1),
    ("prompt_revision", -1),
    ("image_sha256", "A" * 64),
    ("record_sha256", "x" * 64),
    ("selected_region_id", 7),
])
def test_context_rejects_invalid_identity_fields(field: str, value: object):
    ctx = context()
    ctx[field] = value
    with pytest.raises(ValueError):
        validate_request(request("predict", ctx=ctx, data=predict_data()))


def test_context_rejects_missing_or_unknown_fields():
    for ctx in ({**context(), "extra": 1}, {key: value for key, value in context().items() if key != "frame_id"}):
        with pytest.raises(ValueError):
            validate_request(request("predict", ctx=ctx, data=predict_data()))


@pytest.mark.parametrize("changes", [
    {"points": [[1.0, 2.0]] * 65, "labels": [1] * 65},
    {"points": [[1.0, 2.0]], "labels": []},
    {"points": [[1.0, float("nan")]]},
    {"points": [[1.0]]},
    {"labels": [2]},
    {"labels": [True]},
    {"box": [10, 20, 10, 40]},
    {"box": [10, 20, 30]},
    {"box": [[10, 20, 30, 40]]},
    {"points": [], "labels": [], "box": None},
    {"extra": 1},
])
def test_predict_rejects_invalid_points_labels_box_or_fields(changes: dict):
    with pytest.raises(ValueError):
        validate_request(request("predict", ctx=context(), data=predict_data(**changes)))


def test_predict_accepts_one_normalized_box_and_optional_initial_mask():
    parsed = validate_request(request("predict", ctx=context(), data=predict_data(
        points=[[1, 2], [3, 4]], labels=[1, 0], box=[10, 20, 30, 40],
        initial_mask=descriptor("initial-mask.png"),
    )))
    assert parsed["data"] == {
        "points": [[1.0, 2.0], [3.0, 4.0]],
        "labels": [1, 0],
        "box": [10.0, 20.0, 30.0, 40.0],
        "initial_mask": descriptor("initial-mask.png"),
    }


@pytest.mark.parametrize("bad", [
    {**descriptor(), "path": "../outside.png"},
    {**descriptor(), "path": "/tmp/input.png"},
    {**descriptor(), "path": "input.jpg"},
    {**descriptor(), "sha256": "0" * 63},
    {**descriptor(), "width": 0},
    {**descriptor(), "height": 1.5},
    {**descriptor(), "extra": 1},
])
def test_image_descriptors_are_bounded_relative_png_metadata(bad: dict):
    with pytest.raises(ValueError):
        validate_request(request("set_image", ctx=context(), data={"image": bad}))


def test_context_free_operations_reject_context_and_wrong_data():
    with pytest.raises(ValueError):
        validate_request(request("hello", ctx=context()))
    with pytest.raises(ValueError):
        validate_request(request("shutdown", data={"extra": 1}))
    with pytest.raises(ValueError):
        validate_request(request("cancel", data={"target_request_id": ""}))


def test_success_and_error_responses_have_exact_error_shapes_and_defensive_data():
    source = request("predict", ctx=context(prompt_revision=4), data=predict_data())
    response = success_response(source, {"candidates": []})
    source["context"]["prompt_revision"] = 99
    assert response == {
        "protocol": "model-assist-v1", "request_id": "r1", "ok": True,
        "context": context(prompt_revision=4), "data": {"candidates": []}, "errors": [],
    }
    failure = error_response("r7", {}, ["prediction failed"])
    assert failure == {
        "protocol": "model-assist-v1", "request_id": "r7", "ok": False,
        "context": {}, "data": {}, "errors": ["prediction failed"],
    }
    for errors in ([], [1], [""], "failed"):
        with pytest.raises(ValueError):
            error_response("r7", {}, errors)  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        success_response(source, {"score": float("nan")})


@pytest.mark.parametrize("raw", [
    b'{"protocol":"model-assist-v1","request_id":"r1","op":"hello","context":{},"data":' + b"[" * 1100 + b"0" + b"]" * 1100 + b"}\n",
    b'{"protocol":"model-assist-v1","request_id":"r1","op":"predict","context":{},"data":{"points":[[1' + b"0" * 400 + b',2]],"labels":[1],"box":null,"initial_mask":null}}\n',
])
def test_extreme_depth_or_number_becomes_a_value_error(raw: bytes):
    with pytest.raises(ValueError):
        loads_line(raw)
