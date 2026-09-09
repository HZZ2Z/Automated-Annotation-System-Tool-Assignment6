"""Bounded pure-data validation for the ``model-assist-v1`` JSONL wire format.

The protocol module never resolves or opens a path.  File authority belongs to
the worker/service job boundary; this layer only accepts relative PNG
descriptors whose bytes and dimensions are checked by that boundary.
"""
from __future__ import annotations

from copy import deepcopy
import json
import math
from pathlib import PurePosixPath
from typing import Any


PROTOCOL = "model-assist-v1"
MAX_LINE_BYTES = 1024 * 1024
MAX_POINTS = 64

_REQUEST_KEYS = frozenset({"protocol", "request_id", "op", "context", "data"})
_RESPONSE_KEYS = frozenset({"protocol", "request_id", "ok", "context", "data", "errors"})
_CONTEXT_KEYS = frozenset({
    "session_id",
    "frame_id",
    "playback_index",
    "image_sha256",
    "record_sha256",
    "selected_region_id",
    "prompt_revision",
})
_DESCRIPTOR_KEYS = frozenset({"path", "sha256", "width", "height"})
_PREDICT_KEYS = frozenset({"points", "labels", "box", "initial_mask"})
_OPS = frozenset({"hello", "set_image", "predict", "cancel", "shutdown"})
_LOWER_HEX = frozenset("0123456789abcdef")


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON constant: {value}")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def _exact_object(value: object, keys: frozenset[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    actual = frozenset(value)
    if actual != keys:
        raise ValueError(
            f"{label} has invalid fields "
            f"(missing={sorted(keys - actual)}, extra={sorted(actual - keys)})"
        )
    return value


def _text(value: object, label: str, *, allow_empty: bool = False, maximum: int = 256) -> str:
    if not isinstance(value, str) or (not allow_empty and not value) or len(value) > maximum:
        qualifier = "a string" if allow_empty else "a non-empty string"
        raise ValueError(f"{label} must be {qualifier} of at most {maximum} characters")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ValueError(f"{label} must be UTF-8 encodable") from exc
    if any(byte < 32 or byte == 127 for byte in encoded):
        raise ValueError(f"{label} must not contain control characters")
    return value


def _request_id(value: object, label: str = "request_id") -> str:
    return _text(value, label, maximum=128)


def _integer(value: object, label: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{label} must be an integer >= {minimum}")
    return value


def _number(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a finite number")
    try:
        normalized = float(value)
    except (OverflowError, ValueError) as exc:
        raise ValueError(f"{label} must be a finite number") from exc
    if not math.isfinite(normalized):
        raise ValueError(f"{label} must be a finite number")
    return normalized


def _digest(value: object, label: str) -> str:
    digest = _text(value, label, maximum=64)
    if len(digest) != 64 or any(character not in _LOWER_HEX for character in digest):
        raise ValueError(f"{label} must be a lower-case SHA-256 digest")
    return digest


def _context(value: object) -> dict[str, Any]:
    source = _exact_object(value, _CONTEXT_KEYS, "context")
    return {
        "session_id": _text(source["session_id"], "context.session_id"),
        "frame_id": _integer(source["frame_id"], "context.frame_id"),
        "playback_index": _integer(source["playback_index"], "context.playback_index"),
        "image_sha256": _digest(source["image_sha256"], "context.image_sha256"),
        "record_sha256": _digest(source["record_sha256"], "context.record_sha256"),
        "selected_region_id": _text(
            source["selected_region_id"], "context.selected_region_id", allow_empty=True
        ),
        "prompt_revision": _integer(source["prompt_revision"], "context.prompt_revision"),
    }


def _descriptor(value: object, label: str) -> dict[str, Any]:
    source = _exact_object(value, _DESCRIPTOR_KEYS, label)
    path_text = _text(source["path"], f"{label}.path", maximum=512)
    path = PurePosixPath(path_text)
    if path.is_absolute() or path.suffix.lower() != ".png" or not path.parts:
        raise ValueError(f"{label}.path must be a relative .png path")
    if any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError(f"{label}.path must not contain traversal")
    return {
        "path": path.as_posix(),
        "sha256": _digest(source["sha256"], f"{label}.sha256"),
        "width": _integer(source["width"], f"{label}.width", minimum=1),
        "height": _integer(source["height"], f"{label}.height", minimum=1),
    }


def _points(value: object) -> list[list[float]]:
    if not isinstance(value, list) or len(value) > MAX_POINTS:
        raise ValueError(f"data.points must be an array of at most {MAX_POINTS} points")
    normalized: list[list[float]] = []
    for index, point in enumerate(value):
        if not isinstance(point, list) or len(point) != 2:
            raise ValueError(f"data.points[{index}] must contain exactly two coordinates")
        normalized.append([
            _number(point[0], f"data.points[{index}][0]"),
            _number(point[1], f"data.points[{index}][1]"),
        ])
    return normalized


def _labels(value: object, count: int) -> list[int]:
    if not isinstance(value, list) or len(value) != count:
        raise ValueError("data.labels must contain exactly one label per point")
    result: list[int] = []
    for index, label in enumerate(value):
        if isinstance(label, bool) or not isinstance(label, int) or label not in (0, 1):
            raise ValueError(f"data.labels[{index}] must be 0 or 1")
        result.append(label)
    return result


def _box(value: object) -> list[float] | None:
    if value is None:
        return None
    if not isinstance(value, list) or len(value) != 4:
        raise ValueError("data.box must be null or one [x0, y0, x1, y1] box")
    result = [_number(coordinate, f"data.box[{index}]") for index, coordinate in enumerate(value)]
    if result[0] >= result[2] or result[1] >= result[3]:
        raise ValueError("data.box must have x0 < x1 and y0 < y1")
    return result


def _predict_data(value: object) -> dict[str, Any]:
    source = _exact_object(value, _PREDICT_KEYS, "data")
    points = _points(source["points"])
    labels = _labels(source["labels"], len(points))
    box = _box(source["box"])
    if not points and box is None:
        raise ValueError("predict requires at least one point or a box")
    initial = source["initial_mask"]
    return {
        "points": points,
        "labels": labels,
        "box": box,
        "initial_mask": None if initial is None else _descriptor(initial, "data.initial_mask"),
    }


def _empty_object(value: object, label: str) -> dict[str, Any]:
    return _exact_object(value, frozenset(), label)


def _validate_json_tree(value: object, label: str) -> None:
    """Reject non-JSON and non-finite values without recursive stack growth."""
    pending: list[tuple[object, int]] = [(value, 0)]
    nodes = 0
    while pending:
        current, depth = pending.pop()
        nodes += 1
        if nodes > 100_000 or depth > 256:
            raise ValueError(f"{label} is too deeply nested or large")
        if current is None or isinstance(current, (str, bool, int)):
            if isinstance(current, str):
                _text(current, label, allow_empty=True, maximum=MAX_LINE_BYTES)
            continue
        if isinstance(current, float):
            if not math.isfinite(current):
                raise ValueError(f"{label} contains a non-finite number")
            continue
        if isinstance(current, list):
            pending.extend((item, depth + 1) for item in current)
            continue
        if isinstance(current, dict):
            for key, item in current.items():
                _text(key, f"{label} key", allow_empty=True, maximum=512)
                pending.append((item, depth + 1))
            continue
        raise ValueError(f"{label} contains a non-JSON value")


def loads_line(raw: bytes) -> dict[str, Any]:
    """Decode and validate exactly one bounded LF-terminated request line."""
    if not isinstance(raw, bytes) or not raw.endswith(b"\n") or len(raw) > MAX_LINE_BYTES:
        raise ValueError(f"request line must be LF-terminated and at most {MAX_LINE_BYTES} bytes")
    if b"\n" in raw[:-1] or b"\r" in raw:
        raise ValueError("request line must contain exactly one terminal LF")
    try:
        text = raw[:-1].decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError) as exc:
        raise ValueError(f"invalid request JSON: {exc}") from exc
    return validate_request(value)


def validate_request(value: object) -> dict[str, Any]:
    """Return a normalized defensive copy of a strict request object."""
    source = _exact_object(value, _REQUEST_KEYS, "request")
    if source["protocol"] != PROTOCOL:
        raise ValueError(f"protocol must be {PROTOCOL}")
    request_id = _request_id(source["request_id"])
    op = source["op"]
    if not isinstance(op, str) or op not in _OPS:
        raise ValueError(f"unsupported operation: {op!r}")

    if op in {"hello", "shutdown"}:
        normalized_context = _empty_object(source["context"], "context")
        normalized_data = _empty_object(source["data"], "data")
    elif op == "cancel":
        normalized_context = _empty_object(source["context"], "context")
        cancel = _exact_object(source["data"], frozenset({"target_request_id"}), "data")
        normalized_data = {"target_request_id": _request_id(cancel["target_request_id"], "data.target_request_id")}
    elif op == "set_image":
        normalized_context = _context(source["context"])
        data = _exact_object(source["data"], frozenset({"image"}), "data")
        normalized_data = {"image": _descriptor(data["image"], "data.image")}
    else:
        normalized_context = _context(source["context"])
        normalized_data = _predict_data(source["data"])

    return {
        "protocol": PROTOCOL,
        "request_id": request_id,
        "op": op,
        "context": normalized_context,
        "data": normalized_data,
    }


def success_response(request: dict[str, Any], data: dict[str, Any]) -> dict[str, Any]:
    """Build a successful response that cannot alias caller-owned data."""
    normalized = validate_request(request)
    if not isinstance(data, dict):
        raise ValueError("response data must be an object")
    _validate_json_tree(data, "response data")
    return {
        "protocol": PROTOCOL,
        "request_id": normalized["request_id"],
        "ok": True,
        "context": deepcopy(normalized["context"]),
        "data": deepcopy(data),
        "errors": [],
    }


def error_response(request_id: str, context: dict[str, Any], errors: list[str]) -> dict[str, Any]:
    """Build a strict failure response with one or more bounded messages."""
    normalized_id = _request_id(request_id)
    if not isinstance(context, dict):
        raise ValueError("response context must be an object")
    _validate_json_tree(context, "response context")
    if not isinstance(errors, list) or not errors or len(errors) > 16:
        raise ValueError("response errors must contain from one to 16 messages")
    normalized_errors = [
        _text(message, f"response errors[{index}]", maximum=512)
        for index, message in enumerate(errors)
    ]
    return {
        "protocol": PROTOCOL,
        "request_id": normalized_id,
        "ok": False,
        "context": deepcopy(context),
        "data": {},
        "errors": normalized_errors,
    }


def validate_response(value: object) -> dict[str, Any]:
    """Validate the common response envelope for service-side consumption."""
    source = _exact_object(value, _RESPONSE_KEYS, "response")
    if source["protocol"] != PROTOCOL:
        raise ValueError(f"protocol must be {PROTOCOL}")
    request_id = _request_id(source["request_id"])
    if not isinstance(source["ok"], bool):
        raise ValueError("response.ok must be boolean")
    if not isinstance(source["context"], dict) or not isinstance(source["data"], dict):
        raise ValueError("response context and data must be objects")
    _validate_json_tree(source["context"], "response context")
    _validate_json_tree(source["data"], "response data")
    errors = source["errors"]
    if not isinstance(errors, list) or any(not isinstance(item, str) or not item for item in errors):
        raise ValueError("response.errors must be an array of non-empty strings")
    if source["ok"] != (len(errors) == 0) or (not source["ok"] and source["data"]):
        raise ValueError("response ok/data/errors fields are inconsistent")
    return deepcopy(source)
