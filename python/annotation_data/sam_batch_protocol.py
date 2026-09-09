"""Strict newline-delimited ``sam-batch-v1`` request and response handling.

The worker is deliberately the only place that supplies ``job_dir``.  Keeping
the root outside the JSON message prevents a request from expanding its own
file-system authority.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import stat
import struct
from typing import Any
import zlib


PROTOCOL = "sam-batch-v1"
MAX_LINE_BYTES = 1024 * 1024
MAX_FRAMES = 30
MAX_POINTS = 64
_REQUEST_KEYS = frozenset({"protocol", "request_id", "op", "context", "data"})
_CONTEXT_KEYS = frozenset({"session_id", "source_digest", "reference_digest", "region_id", "prompt_revision"})
_FRAME_KEYS = frozenset({"index", "frame_id", "time_s", "path", "sha256", "width", "height", "gap"})
_REGION_KEYS = frozenset({"id", "polygon"})
_REANCHOR_KEYS = frozenset({"frame_index", "positive_points", "negative_points", "box", "prompt_revision"})
_HEX64 = frozenset("0123456789abcdef")


@dataclass(frozen=True)
class SamBatchRequest:
    """A fully validated request whose dictionaries contain only JSON values."""

    request_id: int
    op: str
    context: dict[str, Any]
    data: dict[str, Any]


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON constant: {value}")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _require_exact_keys(value: Any, keys: frozenset[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    actual = frozenset(value)
    if actual != keys:
        missing = sorted(keys - actual)
        extra = sorted(actual - keys)
        raise ValueError(f"{label} has invalid fields (missing={missing}, extra={extra})")
    return value


def _require_int(value: Any, label: str, *, minimum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{label} must be an integer")
    if minimum is not None and value < minimum:
        raise ValueError(f"{label} must be at least {minimum}")
    return value


def _require_number(value: Any, label: str, *, minimum: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a number")
    try:
        number = float(value)
    except (OverflowError, ValueError) as exc:
        raise ValueError(f"{label} must be finite") from exc
    if not math.isfinite(number):
        raise ValueError(f"{label} must be finite")
    if minimum is not None and number < minimum:
        raise ValueError(f"{label} must be at least {minimum}")
    return number


def _require_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} must be a non-empty string")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ValueError(f"{label} must be UTF-8 encodable") from exc
    return value


def _require_digest(value: Any, label: str) -> str:
    digest = _require_text(value, label)
    if len(digest) != 64 or any(character not in _HEX64 for character in digest):
        raise ValueError(f"{label} must be a lower-case SHA-256 digest")
    return digest


def _reject_non_finite(value: Any) -> None:
    pending = [value]
    while pending:
        current = pending.pop()
        if isinstance(current, float) and not math.isfinite(current):
            raise ValueError("JSON contains a non-finite number")
        if isinstance(current, dict):
            pending.extend(current.values())
        elif isinstance(current, list):
            pending.extend(current)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _png_dimensions(path: Path) -> tuple[int, int]:
    with path.open("rb") as handle:
        if handle.read(8) != b"\x89PNG\r\n\x1a\n":
            raise ValueError("frame path is not a PNG")
        width = height = 0
        saw_ihdr = saw_idat = False
        while True:
            length_bytes = handle.read(4)
            if len(length_bytes) != 4:
                raise ValueError("PNG is missing a terminal chunk")
            length = struct.unpack(">I", length_bytes)[0]
            if length > 64 * 1024 * 1024:
                raise ValueError("PNG chunk is unreasonably large")
            kind = handle.read(4)
            chunk = handle.read(length)
            checksum = handle.read(4)
            if len(kind) != 4 or len(chunk) != length or len(checksum) != 4:
                raise ValueError("PNG chunk is truncated")
            if struct.unpack(">I", checksum)[0] != zlib.crc32(kind + chunk) & 0xFFFFFFFF:
                raise ValueError("PNG chunk checksum does not match")
            if not saw_ihdr:
                if kind != b"IHDR" or length != 13:
                    raise ValueError("PNG must begin with IHDR")
                width, height = struct.unpack(">II", chunk[:8])
                saw_ihdr = True
            elif kind == b"IDAT":
                saw_idat = True
            elif kind == b"IEND":
                if length != 0 or not saw_idat or handle.read(1):
                    raise ValueError("PNG must contain IDAT and end at IEND")
                break
    if width <= 0 or height <= 0:
        raise ValueError("PNG dimensions must be positive")
    return width, height


def _resolve_png_path(value: Any, job_dir: Path | None) -> str:
    text = _require_text(value, "frame.path")
    raw = Path(text)
    if not raw.is_absolute() or raw.suffix != ".png":
        raise ValueError("frame.path must be an absolute .png path")
    if ".." in raw.parts:
        raise ValueError("frame.path must not contain traversal")
    try:
        resolved = raw.resolve(strict=True)
    except OSError as exc:
        raise ValueError(f"frame.path cannot be resolved: {exc}") from exc
    try:
        metadata = resolved.stat()
    except OSError as exc:
        raise ValueError(f"frame.path cannot be statted: {exc}") from exc
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("frame.path must be a regular file")
    if job_dir is not None:
        try:
            root = Path(job_dir).resolve(strict=True)
        except OSError as exc:
            raise ValueError(f"job directory cannot be resolved: {exc}") from exc
        if not stat.S_ISDIR(root.stat().st_mode):
            raise ValueError("job directory must be a directory")
        try:
            resolved.relative_to(root)
        except ValueError as exc:
            raise ValueError("frame.path is outside the job directory") from exc
    return str(resolved)


def _validate_context(value: Any) -> dict[str, Any]:
    context = _require_exact_keys(value, _CONTEXT_KEYS, "context")
    normalized = {
        "session_id": _require_text(context["session_id"], "context.session_id"),
        "source_digest": _require_digest(context["source_digest"], "context.source_digest"),
        "reference_digest": _require_digest(context["reference_digest"], "context.reference_digest"),
        "region_id": _require_text(context["region_id"], "context.region_id"),
        "prompt_revision": _require_int(context["prompt_revision"], "context.prompt_revision", minimum=0),
    }
    return normalized


def _validate_point_list(value: Any, label: str) -> list[list[float]]:
    if not isinstance(value, list):
        raise ValueError(f"{label} must be an array")
    normalized: list[list[float]] = []
    for index, point in enumerate(value):
        if not isinstance(point, list) or len(point) != 2:
            raise ValueError(f"{label}[{index}] must contain exactly two coordinates")
        normalized.append([
            _require_number(point[0], f"{label}[{index}][0]"),
            _require_number(point[1], f"{label}[{index}][1]"),
        ])
    return normalized


def _validate_region(value: Any) -> dict[str, Any]:
    region = _require_exact_keys(value, _REGION_KEYS, "data.region")
    polygon = _validate_point_list(region["polygon"], "data.region.polygon")
    if len(polygon) < 3:
        raise ValueError("data.region.polygon must contain at least three points")
    return {"id": _require_text(region["id"], "data.region.id"), "polygon": polygon}


def _validate_open_batch(value: Any, job_dir: Path | None) -> dict[str, Any]:
    data = _require_exact_keys(value, frozenset({"frames", "key_index", "region"}), "data")
    frames = data["frames"]
    if not isinstance(frames, list) or not frames or len(frames) > MAX_FRAMES:
        raise ValueError(f"data.frames must contain from one to {MAX_FRAMES} frames")
    normalized_frames: list[dict[str, Any]] = []
    previous_frame_id: int | None = None
    previous_time: float | None = None
    for expected_index, item in enumerate(frames):
        frame = _require_exact_keys(item, _FRAME_KEYS, f"data.frames[{expected_index}]")
        index = _require_int(frame["index"], f"data.frames[{expected_index}].index", minimum=0)
        if index != expected_index:
            raise ValueError("frame indices must be contiguous playback indices starting at zero")
        frame_id = _require_int(frame["frame_id"], f"data.frames[{expected_index}].frame_id", minimum=0)
        if previous_frame_id is not None and frame_id <= previous_frame_id:
            raise ValueError("frame IDs must be strictly increasing")
        time_s = _require_number(frame["time_s"], f"data.frames[{expected_index}].time_s", minimum=0)
        if previous_time is not None and time_s < previous_time:
            raise ValueError("frame times must be ordered")
        gap = _require_int(frame["gap"], f"data.frames[{expected_index}].gap", minimum=0)
        if gap != (0 if previous_frame_id is None else frame_id - previous_frame_id):
            raise ValueError("frame gap must match adjacent original frame IDs")
        path = _resolve_png_path(frame["path"], job_dir)
        width = _require_int(frame["width"], f"data.frames[{expected_index}].width", minimum=1)
        height = _require_int(frame["height"], f"data.frames[{expected_index}].height", minimum=1)
        png_width, png_height = _png_dimensions(Path(path))
        if (width, height) != (png_width, png_height):
            raise ValueError("frame dimensions do not match the PNG")
        digest = _require_digest(frame["sha256"], f"data.frames[{expected_index}].sha256")
        if digest != _sha256_file(Path(path)):
            raise ValueError("frame digest does not match the PNG")
        normalized_frames.append({
            "index": index, "frame_id": frame_id, "time_s": time_s, "path": path,
            "sha256": digest, "width": width, "height": height, "gap": gap,
        })
        previous_frame_id, previous_time = frame_id, time_s
    key_index = _require_int(data["key_index"], "data.key_index", minimum=0)
    if key_index >= len(normalized_frames):
        raise ValueError("data.key_index must name a frame")
    return {"frames": normalized_frames, "key_index": key_index, "region": _validate_region(data["region"])}


def _validate_reanchor(value: Any) -> dict[str, Any]:
    data = _require_exact_keys(value, _REANCHOR_KEYS, "data") if isinstance(value, dict) and "box" in value else _require_exact_keys(value, _REANCHOR_KEYS - {"box"}, "data")
    positive = _validate_point_list(data["positive_points"], "data.positive_points")
    negative = _validate_point_list(data["negative_points"], "data.negative_points")
    if len(positive) + len(negative) > MAX_POINTS:
        raise ValueError(f"reanchor supports at most {MAX_POINTS} points")
    normalized: dict[str, Any] = {
        "frame_index": _require_int(data["frame_index"], "data.frame_index", minimum=0),
        "positive_points": positive,
        "negative_points": negative,
        "prompt_revision": _require_int(data["prompt_revision"], "data.prompt_revision", minimum=1),
    }
    if "box" in data:
        box = data["box"]
        if not isinstance(box, list) or len(box) != 4:
            raise ValueError("data.box must contain exactly four coordinates")
        normalized_box = [_require_number(part, f"data.box[{index}]") for index, part in enumerate(box)]
        if normalized_box[2] <= 0 or normalized_box[3] <= 0:
            raise ValueError("data.box width and height must be positive")
        normalized["box"] = normalized_box
    return normalized


def parse_request(line: bytes, *, job_dir: Path | None = None) -> SamBatchRequest:
    """Parse exactly one wire line, optionally constraining PNGs to ``job_dir``."""
    if not isinstance(line, bytes):
        raise ValueError("request line must be bytes")
    if not line.endswith(b"\n") or line.count(b"\n") != 1 or len(line) > MAX_LINE_BYTES:
        raise ValueError("request must be one newline-terminated line no larger than 1 MiB")
    try:
        decoded = line[:-1].decode("utf-8")
        payload = json.loads(decoded, parse_constant=_reject_constant, object_pairs_hook=_reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, OverflowError, RecursionError) as exc:
        raise ValueError(f"invalid JSON request: {exc}") from exc
    _reject_non_finite(payload)
    request = _require_exact_keys(payload, _REQUEST_KEYS, "request")
    if request["protocol"] != PROTOCOL:
        raise ValueError("unsupported protocol")
    request_id = _require_int(request["request_id"], "request_id", minimum=1)
    op = request["op"]
    if not isinstance(op, str) or op not in {"hello", "open_batch", "propagate", "reanchor", "shutdown"}:
        raise ValueError("unknown operation")
    if op in {"hello", "shutdown"}:
        if request["context"] != {} or request["data"] != {}:
            raise ValueError(f"{op} requires empty context and data")
        context: dict[str, Any] = {}
        data: dict[str, Any] = {}
    else:
        context = _validate_context(request["context"])
        if op == "open_batch":
            data = _validate_open_batch(request["data"], job_dir)
        elif op == "propagate":
            if request["data"] != {}:
                raise ValueError("propagate requires empty data")
            data = {}
        else:
            data = _validate_reanchor(request["data"])
    return SamBatchRequest(request_id=request_id, op=op, context=context, data=data)


def encode_response(request_id: int, ok: bool, context: dict, data: dict, errors: list[str]) -> bytes:
    """Encode exactly one compact response line; stdout callers write nothing else."""
    normalized_id = _require_int(request_id, "request_id", minimum=1)
    if not isinstance(ok, bool):
        raise ValueError("ok must be a boolean")
    if not isinstance(context, dict) or not isinstance(data, dict):
        raise ValueError("response context and data must be objects")
    if not isinstance(errors, list) or any(not isinstance(error, str) for error in errors):
        raise ValueError("response errors must be a list of strings")
    payload = {"protocol": PROTOCOL, "request_id": normalized_id, "ok": ok,
               "context": context, "data": data, "errors": errors}
    try:
        return (json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ValueError(f"response is not JSON-safe: {exc}") from exc
