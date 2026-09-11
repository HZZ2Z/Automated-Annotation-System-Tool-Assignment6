"""Strict bounded validation for the ``sam-video-v1`` JSONL protocol.

This module handles pure data only.  It never resolves or reads descriptor
paths; the job-scoped backend owns that file authority boundary.
"""
from __future__ import annotations

from copy import deepcopy
import json
import math
from pathlib import PurePosixPath
from typing import Any


PROTOCOL = "sam-video-v1"
MAX_LINE_BYTES = 1_048_576
MAX_TARGETS = 30
OBJECT_ID = 1

_REQUEST_KEYS = frozenset({"protocol", "request_id", "op", "context", "data"})
_RESPONSE_KEYS = frozenset({"protocol", "request_id", "ok", "context", "data", "errors"})
_CONTEXT_REQUIRED_KEYS = frozenset({
    "session_id",
    "request_nonce",
    "key_playback_index",
    "key_frame_id",
    "targets",
    "store_revision",
    "review_sha256",
    "key_record_sha256",
    "region_id",
    "propagation_count",
    "requested_device",
})
_CONTEXT_OPTIONAL_KEYS = frozenset({"key_time_s"})
_TARGET_REQUIRED_KEYS = frozenset({
    "playback_index", "frame_id", "entry_sha256", "image_sha256"
})
_TARGET_OPTIONAL_KEYS = frozenset({"time_s"})
_FRAME_KEYS = frozenset({
    "path", "sha256", "width", "height", "playback_index", "frame_id"
})
_MASK_KEYS = frozenset({"path", "sha256", "roi"})
_OPS = frozenset({
    "hello", "open_batch", "add_mask", "propagate", "cancel", "reset_batch", "shutdown"
})
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


def _object_with_optional(
    value: object,
    required: frozenset[str],
    optional: frozenset[str],
    label: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    actual = frozenset(value)
    missing = required - actual
    extra = actual - required - optional
    if missing or extra:
        raise ValueError(
            f"{label} has invalid fields (missing={sorted(missing)}, extra={sorted(extra)})"
        )
    return value


def _text(value: object, label: str, *, maximum: int = 256) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise ValueError(f"{label} must be a non-empty string of at most {maximum} characters")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ValueError(f"{label} must be UTF-8 encodable") from exc
    if any(byte < 32 or byte == 127 for byte in encoded):
        raise ValueError(f"{label} must not contain control characters")
    return value


def _request_id(value: object, label: str = "request_id") -> str:
    return _text(value, label, maximum=128)


def _integer(
    value: object,
    label: str,
    *,
    minimum: int = 0,
    maximum: int | None = None,
) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{label} must be an integer >= {minimum}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{label} must be an integer <= {maximum}")
    return value


def _finite_number(value: object, label: str) -> int | float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a finite number")
    try:
        finite = math.isfinite(value)
    except (OverflowError, TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be a finite number") from exc
    if not finite:
        raise ValueError(f"{label} must be a finite number")
    return value


def _digest(value: object, label: str) -> str:
    digest = _text(value, label, maximum=64)
    if len(digest) != 64 or any(character not in _LOWER_HEX for character in digest):
        raise ValueError(f"{label} must be a lower-case SHA-256 digest")
    return digest


def _relative_png(value: object, label: str) -> str:
    path_text = _text(value, label, maximum=512)
    path = PurePosixPath(path_text)
    if (
        path.is_absolute()
        or path.suffix.lower() != ".png"
        or not path.parts
        or "\\" in path_text
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise ValueError(f"{label} must be a traversal-free relative PNG path")
    return path.as_posix()


def _target(value: object, index: int) -> dict[str, Any]:
    label = f"context.targets[{index}]"
    source = _object_with_optional(
        value, _TARGET_REQUIRED_KEYS, _TARGET_OPTIONAL_KEYS, label
    )
    result: dict[str, Any] = {
        "playback_index": _integer(source["playback_index"], f"{label}.playback_index"),
        "frame_id": _integer(source["frame_id"], f"{label}.frame_id"),
    }
    if "time_s" in source:
        result["time_s"] = _finite_number(source["time_s"], f"{label}.time_s")
    result.update({
        "entry_sha256": _digest(source["entry_sha256"], f"{label}.entry_sha256"),
        "image_sha256": _digest(source["image_sha256"], f"{label}.image_sha256"),
    })
    return result


def _context(value: object) -> dict[str, Any]:
    source = _object_with_optional(
        value, _CONTEXT_REQUIRED_KEYS, _CONTEXT_OPTIONAL_KEYS, "context"
    )
    propagation_count = _integer(
        source["propagation_count"],
        "context.propagation_count",
        minimum=1,
        maximum=MAX_TARGETS,
    )
    raw_targets = source["targets"]
    if not isinstance(raw_targets, list) or not 1 <= len(raw_targets) <= MAX_TARGETS:
        raise ValueError(f"context.targets must contain from 1 to {MAX_TARGETS} targets")
    if len(raw_targets) != propagation_count:
        raise ValueError("context.targets size must equal context.propagation_count")
    targets = [_target(item, index) for index, item in enumerate(raw_targets)]
    key_playback_index = _integer(
        source["key_playback_index"], "context.key_playback_index"
    )
    previous = key_playback_index
    for target in targets:
        current = target["playback_index"]
        if current <= previous:
            raise ValueError("context target playback indices must be unique, sorted and forward")
        previous = current
    requested_device = source["requested_device"]
    if requested_device not in {"auto", "cpu", "cuda"} or not isinstance(requested_device, str):
        raise ValueError("context.requested_device must be auto, cpu or cuda")
    result: dict[str, Any] = {
        "session_id": _text(source["session_id"], "context.session_id"),
        "request_nonce": _text(source["request_nonce"], "context.request_nonce"),
        "key_playback_index": key_playback_index,
        "key_frame_id": _integer(source["key_frame_id"], "context.key_frame_id"),
    }
    if "key_time_s" in source:
        result["key_time_s"] = _finite_number(source["key_time_s"], "context.key_time_s")
    result.update({
        "targets": targets,
        "store_revision": _integer(source["store_revision"], "context.store_revision"),
        "review_sha256": _digest(source["review_sha256"], "context.review_sha256"),
        "key_record_sha256": _digest(
            source["key_record_sha256"], "context.key_record_sha256"
        ),
        "region_id": _text(source["region_id"], "context.region_id"),
        "propagation_count": propagation_count,
        "requested_device": requested_device,
    })
    return result


def _frame(value: object, index: int) -> dict[str, Any]:
    label = f"data.frames[{index}]"
    source = _exact_object(value, _FRAME_KEYS, label)
    return {
        "path": _relative_png(source["path"], f"{label}.path"),
        "sha256": _digest(source["sha256"], f"{label}.sha256"),
        "width": _integer(source["width"], f"{label}.width", minimum=1),
        "height": _integer(source["height"], f"{label}.height", minimum=1),
        "playback_index": _integer(source["playback_index"], f"{label}.playback_index"),
        "frame_id": _integer(source["frame_id"], f"{label}.frame_id"),
    }


def _open_batch_data(value: object, context: dict[str, Any]) -> dict[str, Any]:
    source = _exact_object(value, frozenset({"frames"}), "data")
    raw_frames = source["frames"]
    expected_count = len(context["targets"]) + 1
    if not isinstance(raw_frames, list) or len(raw_frames) != expected_count:
        raise ValueError("data.frames size must equal context.targets size plus one")
    frames = [_frame(item, index) for index, item in enumerate(raw_frames)]
    expected_identities = [
        (context["key_playback_index"], context["key_frame_id"]),
        *((item["playback_index"], item["frame_id"]) for item in context["targets"]),
    ]
    actual_identities = [
        (item["playback_index"], item["frame_id"]) for item in frames
    ]
    if actual_identities != expected_identities:
        raise ValueError("data.frames identities must equal the key then ordered targets")
    if len({item["path"] for item in frames}) != len(frames):
        raise ValueError("data.frames paths must be unique")
    return {"frames": frames}


def _mask(value: object) -> dict[str, Any]:
    source = _exact_object(value, _MASK_KEYS, "data.mask")
    roi = source["roi"]
    if not isinstance(roi, list) or len(roi) != 4:
        raise ValueError("data.mask.roi must be [x, y, width, height]")
    normalized_roi = [
        _integer(item, f"data.mask.roi[{index}]", minimum=0)
        for index, item in enumerate(roi)
    ]
    if normalized_roi[2] == 0 or normalized_roi[3] == 0:
        raise ValueError("data.mask.roi width and height must be positive")
    return {
        "path": _relative_png(source["path"], "data.mask.path"),
        "sha256": _digest(source["sha256"], "data.mask.sha256"),
        "roi": normalized_roi,
    }


def _object_id(value: object, label: str = "data.object_id") -> int:
    object_id = _integer(value, label, minimum=OBJECT_ID, maximum=OBJECT_ID)
    if object_id != OBJECT_ID:
        raise ValueError(f"{label} must be {OBJECT_ID}")
    return object_id


def _empty_data(value: object) -> dict[str, Any]:
    _exact_object(value, frozenset(), "data")
    return {}


def _validate_json_tree(value: object, label: str) -> None:
    pending: list[tuple[object, int]] = [(value, 0)]
    nodes = 0
    while pending:
        current, depth = pending.pop()
        nodes += 1
        if nodes > 100_000 or depth > 256:
            raise ValueError(f"{label} is too deeply nested or large")
        if current is None or isinstance(current, (bool, int)):
            continue
        if isinstance(current, str):
            try:
                encoded = current.encode("utf-8")
            except UnicodeEncodeError as exc:
                raise ValueError(f"{label} contains non-UTF-8 text") from exc
            if any(byte < 32 or byte == 127 for byte in encoded):
                raise ValueError(f"{label} contains control characters")
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
                if not isinstance(key, str):
                    raise ValueError(f"{label} contains a non-string key")
                pending.append((key, depth + 1))
                pending.append((item, depth + 1))
            continue
        raise ValueError(f"{label} contains a non-JSON value")


def loads_line(raw: bytes) -> dict[str, Any]:
    """Decode and validate one LF-terminated request no larger than one MiB."""
    if not isinstance(raw, bytes) or not raw.endswith(b"\n") or len(raw) > MAX_LINE_BYTES:
        raise ValueError(f"request line must be LF-terminated and at most {MAX_LINE_BYTES} bytes")
    if b"\n" in raw[:-1] or b"\r" in raw:
        raise ValueError("request line must contain exactly one terminal LF")
    try:
        value = json.loads(
            raw[:-1].decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError) as exc:
        raise ValueError(f"invalid request JSON: {exc}") from exc
    return validate_request(value)


def validate_request(value: object) -> dict[str, Any]:
    """Return a normalized defensive copy of one exact request."""
    source = _exact_object(value, _REQUEST_KEYS, "request")
    if source["protocol"] != PROTOCOL:
        raise ValueError(f"protocol must be {PROTOCOL}")
    request_id = _request_id(source["request_id"])
    op = source["op"]
    if not isinstance(op, str) or op not in _OPS:
        raise ValueError(f"unsupported operation: {op!r}")
    normalized_context = _context(source["context"])
    if op in {"hello", "reset_batch", "shutdown"}:
        data = _empty_data(source["data"])
    elif op == "open_batch":
        data = _open_batch_data(source["data"], normalized_context)
    elif op == "add_mask":
        raw = _exact_object(source["data"], frozenset({"mask", "object_id"}), "data")
        data = {"mask": _mask(raw["mask"]), "object_id": _object_id(raw["object_id"])}
    elif op == "propagate":
        raw = _exact_object(source["data"], frozenset({"count", "object_id"}), "data")
        count = _integer(raw["count"], "data.count", minimum=1, maximum=MAX_TARGETS)
        if count != normalized_context["propagation_count"]:
            raise ValueError("data.count must equal context.propagation_count")
        data = {"count": count, "object_id": _object_id(raw["object_id"])}
    else:
        raw = _exact_object(source["data"], frozenset({"target_request_id"}), "data")
        data = {"target_request_id": _request_id(
            raw["target_request_id"], "data.target_request_id"
        )}
    return {
        "protocol": PROTOCOL,
        "request_id": request_id,
        "op": op,
        "context": normalized_context,
        "data": data,
    }


def success_response(request: dict[str, Any], data: dict[str, Any]) -> dict[str, Any]:
    """Build an exact success envelope without aliasing caller-owned data."""
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
    """Build an exact failure envelope with bounded finite JSON data."""
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
    """Validate the shared response envelope for service-side consumption."""
    source = _exact_object(value, _RESPONSE_KEYS, "response")
    if source["protocol"] != PROTOCOL:
        raise ValueError(f"protocol must be {PROTOCOL}")
    _request_id(source["request_id"])
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
