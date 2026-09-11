#!/usr/bin/env python3
"""Run only explicitly allowlisted SAM Video cases and keep evidence separate.

An empty allowlist or unavailable external runtime is a successful report
generation with ``NOT RUN`` evidence, never a fabricated model PASS.  This
runner installs and downloads nothing and never searches outside case paths.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from numbers import Real
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from typing import Any, Callable, Mapping

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parents[2]
PYTHON_DIR = ROOT / "python"
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

from sam_video_smoke import _topology, ordered_frame_sources, rasterize_start_mask


SCHEMA = "project6-sam-video-acceptance-v1"
CASES_SCHEMA = "project6-sam-video-cases-v1"
VISIBLE_UI_SCHEMA = "project6-sam-video-visible-ui-v1"
VISIBLE_UI_CHECKS = (
    "preview",
    "early_stop",
    "cancel",
    "prefix_confirm",
    "undo_redo",
    "save_reopen",
    "reanchor",
    "new_batch",
)
REQUIRED_TAGS = (
    "stable",
    "fast_motion",
    "low_contrast_or_glare",
    "occlusion_or_disappearance",
)
ENVIRONMENT_NAMES = (
    "PROJECT6_MODEL_PYTHON",
    "PROJECT6_SAM2_CONFIG",
    "PROJECT6_SAM2_CHECKPOINT",
    "PROJECT6_SAM2_DEVICE",
)
CASE_KEYS = {
    "id",
    "tag",
    "frames",
    "box",
    "polygon",
    "independent_truth",
    "human_review",
    "paired_timing",
}
_PORTABLE_BASENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_PORTABLE_ARTIFACT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_PORTABLE_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+\-]{0,63}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_ABSOLUTE_PATH = re.compile(r"(?<![A-Za-z0-9])(?:/[^\s'\";,]+)+")
_WINDOWS_ABSOLUTE_PATH = re.compile(r"(?<![A-Za-z0-9])[A-Za-z]:\\\\[^\s'\";,]+")
_MAX_REASON_LENGTH = 160
_CANDIDATE_KEYS = {
    "local_index",
    "playback_index",
    "frame_id",
    "object_id",
    "path",
    "roi",
    "score",
    "sha256",
    "topology",
}
_INPUT_FRAME_KEYS = {
    "name",
    "sha256",
    "width",
    "height",
    "playback_index",
    "frame_id",
}
_SMOKE_REPORT_KEYS = {
    "schema",
    "status",
    "reason",
    "environment",
    "input",
    "timings_ms",
    "candidates",
    "stop",
    "artifacts",
    "cuda",
}
_SMOKE_ENVIRONMENT_KEYS = {
    "python_version",
    "torch_version",
    "sam2_version",
    "cuda_available",
    "requested_device",
    "actual_device",
    "config_sha256",
    "checkpoint_sha256",
}
_PREFLIGHT_PASS_KEYS = {"status", "reason", "cuda_device"} | (
    _SMOKE_ENVIRONMENT_KEYS - {"actual_device"}
)
_SMOKE_CUDA_KEYS = {
    "peak_vram_bytes",
    "per_frame_propagate_ms",
    "inflight_cancel_latency_ms",
}
_TIMING_KEYS = {"load", "open", "propagate"}
_MAX_CANDIDATE_BYTES = 64 * 1024 * 1024
_MAX_JSON_DEPTH = 64


def _persisted_reason(value: object, fallback: str) -> str:
    if not isinstance(value, str) or not value:
        return fallback
    if (
        len(value) > _MAX_REASON_LENGTH
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
        or _ABSOLUTE_PATH.search(value) is not None
        or _WINDOWS_ABSOLUTE_PATH.search(value) is not None
    ):
        return fallback
    return value


def _not_run(reason: str, **extra: Any) -> dict[str, Any]:
    return {
        "status": "NOT RUN",
        "reason": _persisted_reason(reason, "evidence prerequisite unavailable"),
        **extra,
    }


def _base_report() -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "environment": _not_run("preflight not performed"),
        "functional": _not_run(
            "no explicit case was run",
            runtime_smoke=_not_run("no explicit case was run", runs=[]),
            visible_ui=_not_run("visible UI evidence was not supplied"),
        ),
        "quality": _not_run("independent target truth was not supplied", cases=[]),
        "efficiency": _not_run("paired manual and SAM timing was not supplied", cases=[]),
        "cuda_performance": _not_run("no actual CUDA run was measured"),
    }


def _bounded_text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 128:
        raise ValueError(f"{label} must be a non-empty string of at most 128 characters")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError(f"{label} must not contain control characters")
    return value


def _strict_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("JSON object contains a duplicate key")
        value[key] = item
    return value


def _reject_nonstandard_json_constant(value: str) -> None:
    raise ValueError(f"nonstandard JSON constant is forbidden: {value}")


def _load_strict_json(payload: str) -> Any:
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_nonstandard_json_constant,
        )
    except RecursionError as exc:
        raise ValueError("JSON nesting exceeds the validation limit") from exc
    _require_finite_json(value)
    return value


def _require_finite_json(value: object) -> None:
    pending: list[tuple[object, int]] = [(value, 0)]
    while pending:
        item, depth = pending.pop()
        if depth > _MAX_JSON_DEPTH:
            raise ValueError("JSON nesting exceeds the validation limit")
        if isinstance(item, float) and not math.isfinite(item):
            raise ValueError("JSON numbers must be finite")
        if isinstance(item, list):
            pending.extend((child, depth + 1) for child in item)
        elif isinstance(item, dict):
            pending.extend((child, depth + 1) for child in item.values())


def _portable_case_id(value: object, label: str) -> str:
    identifier = _bounded_text(value, label)
    if (
        identifier in {".", ".."}
        or "/" in identifier
        or "\\" in identifier
        or _PORTABLE_BASENAME.fullmatch(identifier) is None
    ):
        raise ValueError(f"{label} must be a strict portable basename")
    return identifier


def _private_child(work: Path, basename: str) -> Path:
    if (
        not isinstance(basename, str)
        or not basename
        or basename in {".", ".."}
        or "/" in basename
        or "\\" in basename
        or Path(basename).name != basename
    ):
        raise ValueError("derived evidence name must be one portable basename")
    try:
        metadata = work.lstat()
        root = work.resolve(strict=True)
    except OSError as exc:
        raise ValueError("private acceptance work directory is unavailable") from exc
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ValueError("private acceptance work must be a regular directory")
    candidate = root / basename
    if candidate.parent != root:
        raise ValueError("derived evidence path escaped private work")
    return candidate


def _absolute_path(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 4096:
        raise ValueError(f"{label} must be a non-empty path of at most 4096 characters")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError(f"{label} must not contain control characters")
    text = value
    path = Path(text)
    if not path.is_absolute():
        raise ValueError(f"{label} must be an absolute allowlisted path")
    return str(path)


def load_cases(path: str | Path) -> dict[str, Any]:
    """Validate the explicit case allowlist without opening any case media."""
    source = Path(path)
    value = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or set(value) != {"schema", "required_tags", "cases"}:
        raise ValueError("case allowlist has invalid top-level fields")
    if value["schema"] != CASES_SCHEMA:
        raise ValueError("case allowlist schema is unsupported")
    tags = value["required_tags"]
    if not isinstance(tags, list) or tags != list(REQUIRED_TAGS):
        raise ValueError("case allowlist required_tags must name the four approved tags")
    cases = value["cases"]
    if not isinstance(cases, list) or len(cases) > 32:
        raise ValueError("case allowlist cases must be a bounded array")
    identifiers: set[str] = set()
    normalized: list[dict[str, Any]] = []
    for index, raw in enumerate(cases):
        label = f"cases[{index}]"
        if not isinstance(raw, dict) or set(raw) != CASE_KEYS:
            raise ValueError(f"{label} has invalid fields")
        identifier = _portable_case_id(raw["id"], f"{label}.id")
        if identifier in identifiers:
            raise ValueError("case IDs must be unique")
        identifiers.add(identifier)
        tag = raw["tag"]
        if tag not in REQUIRED_TAGS:
            raise ValueError(f"{label}.tag is not one of the approved case tags")
        frames = _absolute_path(raw["frames"], f"{label}.frames")
        # Geometry is validated by the same rasterizer used to create the real
        # key mask, after the allowlisted frame dimensions are known.
        if not isinstance(raw["box"], list) or len(raw["box"]) != 4:
            raise ValueError(f"{label}.box must contain Model Output V1 box geometry")
        if not isinstance(raw["polygon"], list) or not 3 <= len(raw["polygon"]) <= 2048:
            raise ValueError(f"{label}.polygon must contain from 3 to 2048 points")
        truth = raw["independent_truth"]
        if truth is not None:
            if not isinstance(truth, list) or len(truth) > 30:
                raise ValueError(f"{label}.independent_truth must be null or a bounded list")
            seen_truth: set[int] = set()
            normalized_truth = []
            for truth_index, item in enumerate(truth):
                if not isinstance(item, dict) or set(item) != {"frame_id", "mask"}:
                    raise ValueError(f"{label}.independent_truth[{truth_index}] has invalid fields")
                frame_id = item["frame_id"]
                if isinstance(frame_id, bool) or not isinstance(frame_id, int) or frame_id < 0:
                    raise ValueError("truth frame_id must be a non-negative integer")
                if frame_id in seen_truth:
                    raise ValueError("truth frame IDs must be unique")
                seen_truth.add(frame_id)
                normalized_truth.append({
                    "frame_id": frame_id,
                    "mask": _absolute_path(item["mask"], "truth mask"),
                })
            truth = normalized_truth
        human = raw["human_review"]
        if human is not None:
            expected = {
                "direct_accept",
                "minor_correction",
                "redraw",
                "reanchor_count",
                "stop_frame",
                "silent_drift",
            }
            if not isinstance(human, dict) or set(human) != expected:
                raise ValueError(f"{label}.human_review has invalid fields")
            for key in expected - {"stop_frame"}:
                number = human[key]
                if isinstance(number, bool) or not isinstance(number, int) or number < 0:
                    raise ValueError(f"{label}.human_review.{key} must be non-negative")
            if human["stop_frame"] is not None and (
                isinstance(human["stop_frame"], bool)
                or not isinstance(human["stop_frame"], int)
                or human["stop_frame"] < 0
            ):
                raise ValueError(f"{label}.human_review.stop_frame is invalid")
        timing = raw["paired_timing"]
        if timing is not None:
            if not isinstance(timing, dict) or set(timing) != {
                "manual_seconds",
                "sam_seconds",
            }:
                raise ValueError(f"{label}.paired_timing has invalid fields")
            for key in ("manual_seconds", "sam_seconds"):
                number = timing[key]
                if (
                    isinstance(number, bool)
                    or not isinstance(number, (int, float))
                    or not math.isfinite(float(number))
                    or number <= 0
                ):
                    raise ValueError(f"{label}.paired_timing.{key} must be positive and finite")
        normalized.append({
            "id": identifier,
            "tag": tag,
            "frames": frames,
            "box": raw["box"],
            "polygon": raw["polygon"],
            "independent_truth": truth,
            "human_review": human,
            "paired_timing": timing,
        })
    return {"schema": CASES_SCHEMA, "required_tags": list(REQUIRED_TAGS), "cases": normalized}


def _load_visible_ui_evidence(path_value: str | Path) -> dict[str, Any]:
    path = Path(path_value)
    if not path.is_absolute():
        raise ValueError("visible UI evidence path must be absolute")
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ValueError("visible UI evidence file is unavailable") from exc
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ValueError("visible UI evidence must be a regular non-symlink file")
    if metadata.st_size > 64 * 1024:
        raise ValueError("visible UI evidence exceeds the 64 KiB limit")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ValueError("visible UI evidence could not be opened") from exc
    try:
        try:
            before = os.fstat(descriptor)
            payload = os.read(descriptor, 64 * 1024 + 1)
            after = os.fstat(descriptor)
        except OSError as exc:
            raise ValueError("visible UI evidence could not be read") from exc
    finally:
        os.close(descriptor)
    try:
        final = path.lstat()
    except OSError as exc:
        raise ValueError("visible UI evidence changed while it was read") from exc
    identities = {
        (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns)
        for item in (before, after, final)
    }
    if len(payload) > 64 * 1024:
        raise ValueError("visible UI evidence exceeds the 64 KiB limit")
    if len(identities) != 1 or len(payload) != after.st_size:
        raise ValueError("visible UI evidence changed while it was read")
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("visible UI evidence is not valid UTF-8 JSON") from exc
    if not isinstance(value, dict) or set(value) != {
        "schema",
        "case_id",
        "runtime",
        "checkpoint_sha256",
        "device",
        "checks",
    }:
        raise ValueError("visible UI evidence has invalid top-level fields")
    if value["schema"] != VISIBLE_UI_SCHEMA:
        raise ValueError("visible UI evidence schema is unsupported")
    case_id = _portable_case_id(value["case_id"], "visible UI case_id")
    runtime = value["runtime"]
    if not isinstance(runtime, dict) or set(runtime) != {
        "python_version",
        "torch_version",
        "sam2_version",
    }:
        raise ValueError("visible UI runtime has invalid fields")
    normalized_runtime = {
        key: _bounded_text(runtime[key], f"visible UI runtime.{key}")
        for key in ("python_version", "torch_version", "sam2_version")
    }
    checkpoint_sha256 = value["checkpoint_sha256"]
    if (
        not isinstance(checkpoint_sha256, str)
        or _SHA256.fullmatch(checkpoint_sha256) is None
    ):
        raise ValueError("visible UI checkpoint_sha256 is invalid")
    device = value["device"]
    if not isinstance(device, str) or device not in ("cpu", "cuda"):
        raise ValueError("visible UI device must be cpu or cuda")
    checks = value["checks"]
    if not isinstance(checks, dict) or set(checks) != set(VISIBLE_UI_CHECKS):
        raise ValueError("visible UI checks have invalid fields")
    if any(
        not isinstance(result, str) or result not in ("PASS", "FAIL")
        for result in checks.values()
    ):
        raise ValueError("visible UI checks must be PASS or FAIL")
    return {
        "case_id": case_id,
        "runtime": normalized_runtime,
        "checkpoint_sha256": checkpoint_sha256,
        "device": device,
        "checks": {name: checks[name] for name in VISIBLE_UI_CHECKS},
    }


def _visible_ui_section(
    evidence_path: str | Path | None,
    cases: list[dict[str, Any]],
    environment: dict[str, Any],
    runs: list[dict[str, Any]],
) -> dict[str, Any]:
    if evidence_path is None:
        return _not_run("visible UI evidence was not supplied")
    try:
        evidence = _load_visible_ui_evidence(evidence_path)
    except ValueError as exc:
        return {
            "status": "FAIL",
            "reason": _persisted_reason(str(exc), "visible UI evidence is invalid"),
        }
    case_ids = {case["id"] for case in cases}
    if evidence["case_id"] not in case_ids:
        return {"status": "FAIL", "reason": "visible UI case is not allowlisted"}
    expected_runtime = {
        key: environment.get(key)
        for key in ("python_version", "torch_version", "sam2_version")
    }
    if evidence["runtime"] != expected_runtime:
        return {"status": "FAIL", "reason": "visible UI runtime binding does not match"}
    if evidence["checkpoint_sha256"] != environment.get("checkpoint_sha256"):
        return {"status": "FAIL", "reason": "visible UI checkpoint binding does not match"}
    case_runs = [run for run in runs if run.get("case_id") == evidence["case_id"]]
    if any(
        not isinstance(run.get("actual_device"), str)
        or run.get("actual_device") not in ("cpu", "cuda")
        or not isinstance(run.get("checkpoint_sha256"), str)
        or _SHA256.fullmatch(run["checkpoint_sha256"]) is None
        for run in case_runs
    ):
        return {"status": "FAIL", "reason": "visible UI smoke binding is malformed"}
    actual_devices = {run.get("actual_device") for run in case_runs}
    checkpoints = {run.get("checkpoint_sha256") for run in case_runs}
    if (
        len(case_runs) != 6
        or actual_devices != {evidence["device"]}
        or checkpoints != {evidence["checkpoint_sha256"]}
    ):
        return {"status": "FAIL", "reason": "visible UI smoke binding does not match"}
    if any(result != "PASS" for result in evidence["checks"].values()):
        return {"status": "FAIL", "reason": "visible UI evidence contains a failed check"}
    return {"status": "PASS", "reason": "", **evidence}


_PROBE = r"""
import importlib.metadata as md
import json
import platform
import re
import sys
import sam2
import torch
try:
    distribution_version = md.version("SAM-2")
except md.PackageNotFoundError:
    distribution_version = ""
portable_version = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+\-]{0,63}$")
module_version = getattr(sam2, "__version__", "")
sam2_version = next((
    value for value in (distribution_version, module_version)
    if isinstance(value, str)
    and value != "unknown"
    and portable_version.fullmatch(value) is not None
), "")
print(json.dumps({
    "python_version": platform.python_version(),
    "torch_version": str(torch.__version__),
    "sam2_version": sam2_version,
    "cuda_available": bool(torch.cuda.is_available()),
    "cuda_device": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
}, allow_nan=False, sort_keys=True, separators=(",", ":")))
"""


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def preflight_environment(environ: Mapping[str, str]) -> dict[str, Any]:
    missing = [name for name in ENVIRONMENT_NAMES if not environ.get(name)]
    if missing:
        return _not_run("missing required environment: " + ", ".join(missing))
    python = Path(environ["PROJECT6_MODEL_PYTHON"])
    config = Path(environ["PROJECT6_SAM2_CONFIG"])
    checkpoint = Path(environ["PROJECT6_SAM2_CHECKPOINT"])
    device = environ["PROJECT6_SAM2_DEVICE"]
    if not isinstance(device, str) or device not in ("auto", "cpu", "cuda"):
        return _not_run("PROJECT6_SAM2_DEVICE must be auto, cpu or cuda")
    if not python.is_absolute() or not python.is_file() or not os.access(python, os.X_OK):
        return _not_run("PROJECT6_MODEL_PYTHON is not an executable file")
    for label, path in (("config", config), ("checkpoint", checkpoint)):
        try:
            metadata = path.lstat()
        except OSError:
            return _not_run(f"configured {label} cannot be inspected")
        if not path.is_absolute() or stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            return _not_run(f"configured {label} must be an absolute regular non-symlink file")
    try:
        completed = subprocess.run(
            [str(python), "-c", _PROBE],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=60,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return _not_run("external runtime probe timed out")
    except OSError:
        return _not_run("external runtime probe could not be started")
    if completed.returncode != 0:
        return _not_run("external runtime lacks usable torch/sam2")
    try:
        runtime = json.loads(completed.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return _not_run("external runtime probe returned invalid JSON")
    if (
        not isinstance(runtime, dict)
        or set(runtime) != {
            "python_version",
            "torch_version",
            "sam2_version",
            "cuda_available",
            "cuda_device",
        }
        or not isinstance(runtime.get("sam2_version"), str)
        or runtime.get("sam2_version") == "unknown"
        or _PORTABLE_VERSION.fullmatch(runtime.get("sam2_version", "")) is None
    ):
        return _not_run("SAM runtime did not report a valid installed model version")
    if device == "cuda" and not runtime.get("cuda_available"):
        return _not_run("CUDA was explicitly requested but is unavailable")
    try:
        checkpoint_sha256 = _sha256_file(checkpoint)
        config_sha256 = _sha256_file(config)
    except OSError:
        return _not_run("configured model files changed during preflight")
    return {
        "status": "PASS",
        "reason": "",
        "requested_device": device,
        "checkpoint_sha256": checkpoint_sha256,
        "config_sha256": config_sha256,
        **runtime,
    }


def _write_png(path: Path, image: np.ndarray) -> None:
    ok, encoded = cv2.imencode(".png", image)
    if not ok:
        raise ValueError("could not encode the derived key mask")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(encoded.tobytes())
        handle.flush()
        os.fsync(handle.fileno())


def _input_frame_descriptor(source: Mapping[str, Any]) -> dict[str, Any]:
    return {key: source[key] for key in _INPUT_FRAME_KEYS}


def _valid_input_frame_descriptor(value: object) -> bool:
    if not isinstance(value, dict) or set(value) != _INPUT_FRAME_KEYS:
        return False
    return (
        isinstance(value.get("name"), str)
        and isinstance(value.get("sha256"), str)
        and _SHA256.fullmatch(value["sha256"]) is not None
        and type(value.get("width")) is int
        and value["width"] > 0
        and type(value.get("height")) is int
        and value["height"] > 0
        and type(value.get("playback_index")) is int
        and value["playback_index"] >= 0
        and type(value.get("frame_id")) is int
        and value["frame_id"] >= 0
    )


def _valid_version(value: object) -> bool:
    return (
        isinstance(value, str)
        and value != "unknown"
        and _PORTABLE_VERSION.fullmatch(value) is not None
    )


def _expected_actual_device(requested: str, cuda_available: bool) -> str:
    if requested == "cuda":
        return "cuda"
    if requested == "cpu":
        return "cpu"
    return "cuda" if cuda_available else "cpu"


def _valid_smoke_environment(
    value: object,
    environ: Mapping[str, str],
) -> bool:
    if not isinstance(value, dict) or set(value) != _SMOKE_ENVIRONMENT_KEYS:
        return False
    requested = value.get("requested_device")
    cuda_available = value.get("cuda_available")
    actual = value.get("actual_device")
    if (
        not isinstance(requested, str)
        or requested not in ("auto", "cpu", "cuda")
        or type(cuda_available) is not bool
        or not isinstance(actual, str)
        or actual not in ("cpu", "cuda")
        or requested != environ.get("PROJECT6_SAM2_DEVICE")
        or actual != _expected_actual_device(requested, cuda_available)
        or not all(
            _valid_version(value.get(key))
            for key in ("python_version", "torch_version", "sam2_version")
        )
    ):
        return False
    try:
        expected_config = _sha256_file(Path(environ["PROJECT6_SAM2_CONFIG"]))
        expected_checkpoint = _sha256_file(Path(environ["PROJECT6_SAM2_CHECKPOINT"]))
    except (KeyError, OSError, TypeError):
        return False
    return (
        isinstance(value.get("config_sha256"), str)
        and _SHA256.fullmatch(value["config_sha256"]) is not None
        and value["config_sha256"] == expected_config
        and isinstance(value.get("checkpoint_sha256"), str)
        and _SHA256.fullmatch(value["checkpoint_sha256"]) is not None
        and value["checkpoint_sha256"] == expected_checkpoint
    )


def _valid_timings(value: object) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == _TIMING_KEYS
        and all(
            type(item) is float and math.isfinite(item) and item >= 0.0
            for item in value.values()
        )
    )


def _valid_cuda(value: object, actual_device: object) -> bool:
    if not isinstance(value, dict) or set(value) != _SMOKE_CUDA_KEYS:
        return False
    peak = value.get("peak_vram_bytes")
    samples = value.get("per_frame_propagate_ms")
    cancel = value.get("inflight_cancel_latency_ms")
    if (
        (peak is not None and (type(peak) is not int or peak < 0))
        or not isinstance(samples, list)
        or any(type(item) is not float or not math.isfinite(item) or item < 0.0 for item in samples)
        or (cancel is not None and (type(cancel) is not float or not math.isfinite(cancel) or cancel < 0.0))
    ):
        return False
    if actual_device == "cpu":
        return peak is None and samples == [] and cancel is None
    return actual_device == "cuda"


def _valid_preflight_pass(value: object) -> bool:
    if not isinstance(value, dict) or set(value) != _PREFLIGHT_PASS_KEYS:
        return False
    requested = value.get("requested_device")
    cuda_available = value.get("cuda_available")
    cuda_device = value.get("cuda_device")
    return (
        value.get("status") == "PASS"
        and value.get("reason") == ""
        and isinstance(requested, str)
        and requested in ("auto", "cpu", "cuda")
        and type(cuda_available) is bool
        and (requested != "cuda" or cuda_available)
        and (
            (cuda_available and isinstance(cuda_device, str) and bool(cuda_device))
            or (not cuda_available and cuda_device is None)
        )
        and all(
            _valid_version(value.get(key))
            for key in ("python_version", "torch_version", "sam2_version")
        )
        and all(
            isinstance(value.get(key), str)
            and _SHA256.fullmatch(value[key]) is not None
            for key in ("config_sha256", "checkpoint_sha256")
        )
    )


def _smoke_environment_matches_preflight(
    smoke_environment: object,
    preflight: Mapping[str, Any],
) -> bool:
    if not isinstance(smoke_environment, dict) or set(smoke_environment) != _SMOKE_ENVIRONMENT_KEYS:
        return False
    if (
        not all(
            _valid_version(smoke_environment.get(key))
            for key in ("python_version", "torch_version", "sam2_version")
        )
        or type(smoke_environment.get("cuda_available")) is not bool
        or not isinstance(smoke_environment.get("requested_device"), str)
        or smoke_environment.get("requested_device") not in ("auto", "cpu", "cuda")
        or not all(
            isinstance(smoke_environment.get(key), str)
            and _SHA256.fullmatch(smoke_environment[key]) is not None
            for key in ("config_sha256", "checkpoint_sha256")
        )
    ):
        return False
    for key in _SMOKE_ENVIRONMENT_KEYS - {"actual_device"}:
        if smoke_environment.get(key) != preflight.get(key):
            return False
    actual = smoke_environment.get("actual_device")
    requested = preflight.get("requested_device")
    cuda_available = preflight.get("cuda_available")
    return (
        isinstance(actual, str)
        and actual in ("cpu", "cuda")
        and isinstance(requested, str)
        and type(cuda_available) is bool
        and actual == _expected_actual_device(requested, cuda_available)
    )


def _valid_pass_topology(value: object, pixel_count: int) -> bool:
    if not isinstance(value, dict) or set(value) != {
        "status",
        "reason",
        "component_count",
        "has_holes",
        "vertex_count",
        "roundtrip_iou",
        "foreground_pixels",
    }:
        return False
    roundtrip_iou = value.get("roundtrip_iou")
    return (
        value.get("status") == "PASS"
        and value.get("reason") == ""
        and type(value.get("component_count")) is int
        and value["component_count"] == 1
        and type(value.get("has_holes")) is bool
        and value["has_holes"] is False
        and type(value.get("vertex_count")) is int
        and 3 <= value["vertex_count"] <= 2048
        and type(roundtrip_iou) is float
        and math.isfinite(roundtrip_iou)
        and 0.99 <= roundtrip_iou <= 1.0
        and type(value.get("foreground_pixels")) is int
        and 0 < value["foreground_pixels"] < pixel_count
    )


def _read_candidate_payload(path: Path) -> bytes:
    try:
        before_path = path.lstat()
    except OSError as exc:
        raise ValueError("candidate artifact cannot be inspected") from exc
    if stat.S_ISLNK(before_path.st_mode) or not stat.S_ISREG(before_path.st_mode):
        raise ValueError("candidate artifact must be a regular non-symlink file")
    if before_path.st_size > _MAX_CANDIDATE_BYTES:
        raise ValueError("candidate artifact exceeds the byte limit")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ValueError("candidate artifact cannot be opened") from exc
    try:
        opened = os.fstat(descriptor)
        chunks: list[bytes] = []
        remaining = _MAX_CANDIDATE_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
    except OSError as exc:
        raise ValueError("candidate artifact cannot be read") from exc
    finally:
        os.close(descriptor)
    payload = b"".join(chunks)
    try:
        final = path.lstat()
    except OSError as exc:
        raise ValueError("candidate artifact changed while it was read") from exc
    identities = {
        (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns)
        for item in (before_path, opened, after, final)
    }
    if (
        len(payload) > _MAX_CANDIDATE_BYTES
        or len(identities) != 1
        or len(payload) != final.st_size
    ):
        raise ValueError("candidate artifact changed while it was read")
    return payload


def _candidate_masks_from_report(
    report: Mapping[str, Any],
    report_path: Path,
    expected_frames: list[dict[str, Any]],
) -> dict[int, np.ndarray]:
    candidates = report.get("candidates")
    artifacts_name = report.get("artifacts")
    if not isinstance(candidates, list):
        raise ValueError("smoke PASS candidates must be an array")
    if (
        not isinstance(artifacts_name, str)
        or _PORTABLE_ARTIFACT_NAME.fullmatch(artifacts_name) is None
    ):
        raise ValueError("smoke PASS artifacts must name one direct child")
    artifacts = report_path.parent / artifacts_name
    try:
        artifacts_metadata = artifacts.lstat()
    except OSError as exc:
        raise ValueError("smoke PASS artifact directory is unavailable") from exc
    if stat.S_ISLNK(artifacts_metadata.st_mode) or not stat.S_ISDIR(
        artifacts_metadata.st_mode
    ):
        raise ValueError("smoke PASS artifacts must be a regular directory")
    expected_names: set[str] = set()
    for candidate in candidates:
        if not isinstance(candidate, dict) or set(candidate) != _CANDIDATE_KEYS:
            raise ValueError("smoke PASS candidate descriptor fields are invalid")
        relative = candidate.get("path")
        if (
            not isinstance(relative, str)
            or _PORTABLE_BASENAME.fullmatch(relative) is None
            or not relative.lower().endswith(".png")
            or relative in expected_names
        ):
            raise ValueError("smoke PASS candidate path is invalid")
        expected_names.add(relative)
    try:
        actual_names = {path.name for path in artifacts.iterdir()}
    except OSError as exc:
        raise ValueError("smoke PASS artifacts cannot be enumerated") from exc
    if actual_names != expected_names:
        raise ValueError("smoke PASS candidate artifact membership is inconsistent")

    image_width = expected_frames[0]["width"]
    image_height = expected_frames[0]["height"]
    masks: dict[int, np.ndarray] = {}
    for position, candidate in enumerate(candidates, start=1):
        if position >= len(expected_frames):
            raise ValueError("smoke PASS candidate descriptor fields are invalid")
        expected = expected_frames[position]
        if (
            candidate["local_index"] != position
            or candidate["playback_index"] != expected["playback_index"]
            or candidate["frame_id"] != expected["frame_id"]
            or candidate["object_id"] != 1
            or any(
                isinstance(candidate[key], bool)
                or not isinstance(candidate[key], int)
                for key in (
                    "local_index",
                    "playback_index",
                    "frame_id",
                    "object_id",
                )
            )
        ):
            raise ValueError("smoke PASS candidate identity is inconsistent")
        score = candidate["score"]
        if type(score) is not float or not math.isfinite(score):
            raise ValueError("smoke PASS candidate score is invalid")
        relative = candidate["path"]
        digest = candidate["sha256"]
        roi = candidate["roi"]
        if (
            not isinstance(digest, str)
            or _SHA256.fullmatch(digest) is None
            or not isinstance(roi, list)
            or len(roi) != 4
            or any(isinstance(value, bool) or not isinstance(value, int) for value in roi)
        ):
            raise ValueError("smoke PASS candidate file descriptor is invalid")
        x, y, width, height = roi
        if (
            x < 0
            or y < 0
            or width <= 0
            or height <= 0
            or x + width > image_width
            or y + height > image_height
        ):
            raise ValueError("smoke PASS candidate ROI is invalid")
        payload = _read_candidate_payload(artifacts / relative)
        if hashlib.sha256(payload).hexdigest() != digest:
            raise ValueError("smoke PASS candidate digest does not match bytes")
        topology = _topology(payload, {"roi": roi}, (image_width, image_height))
        if (
            not _valid_pass_topology(candidate["topology"], image_width * image_height)
            or topology.get("status") != "PASS"
            or candidate["topology"] != topology
        ):
            raise ValueError("smoke PASS candidate topology is invalid")
        crop = cv2.imdecode(np.frombuffer(payload, np.uint8), cv2.IMREAD_GRAYSCALE)
        if crop is None or crop.shape != (height, width):
            raise ValueError("smoke PASS candidate PNG dimensions are invalid")
        full = np.zeros((image_height, image_width), np.uint8)
        full[y:y + height, x:x + width] = crop
        masks[candidate["frame_id"]] = full
    return masks


def _invoke_real_smoke(
    case: dict[str, Any],
    geometry_name: str,
    count: int,
    environ: Mapping[str, str],
    work: Path,
) -> dict[str, Any]:
    frames = ordered_frame_sources(case["frames"], count)
    size = (frames[0]["width"], frames[0]["height"])
    geometry = {geometry_name: case[geometry_name]}
    mask = rasterize_start_mask(size, geometry)
    mask_path = _private_child(
        work, f"{case['id']}-{geometry_name}-{count}-mask.png"
    )
    report_path = _private_child(
        work, f"{case['id']}-{geometry_name}-{count}.json"
    )
    _write_png(mask_path, mask)
    try:
        completed = subprocess.run(
            [
                environ["PROJECT6_MODEL_PYTHON"],
                str(PYTHON_DIR / "sam_video_smoke.py"),
                "--frames",
                case["frames"],
                "--mask",
                str(mask_path),
                "--count",
                str(count),
                "--json-out",
                str(report_path),
            ],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=900,
            check=False,
            env=dict(environ),
            cwd=str(ROOT),
        )
    except subprocess.TimeoutExpired:
        return {"status": "FAIL", "reason": "smoke process timed out"}
    except OSError:
        return {"status": "FAIL", "reason": "smoke process could not be started"}
    if not report_path.is_file():
        return {"status": "FAIL", "reason": "smoke process produced no report"}
    try:
        report = _load_strict_json(report_path.read_text(encoding="utf-8"))
    except (
        OSError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        RecursionError,
        ValueError,
    ):
        return {"status": "FAIL", "reason": "smoke process produced an invalid report"}
    if not isinstance(report, dict):
        return {"status": "FAIL", "reason": "smoke process produced an invalid report"}
    candidate_masks: dict[int, np.ndarray] = {}
    expected_input_frames = [_input_frame_descriptor(item) for item in frames]
    input_value = report.get("input")
    candidates_value = report.get("candidates")
    environment_value = report.get("environment")
    timings_value = report.get("timings_ms")
    cuda_value = report.get("cuda")
    input_frames: object = []
    effective_status = report.get("status", "FAIL")
    effective_reason = report.get("reason", "")
    if (
        not isinstance(effective_status, str)
        or effective_status not in ("PASS", "NOT RUN", "FAIL")
    ):
        effective_status = "FAIL"
        effective_reason = "smoke report status is invalid"
    if effective_status == "PASS":
        try:
            if completed.returncode != 0:
                raise ValueError("smoke process contradicted its PASS report")
            if set(report) != _SMOKE_REPORT_KEYS or report.get("schema") != "project6-sam-video-smoke-v1":
                raise ValueError("smoke process produced an invalid PASS report")
            if not isinstance(input_value, dict) or set(input_value) != {
                "count",
                "key_mask_sha256",
                "frames",
            }:
                raise ValueError("smoke PASS input descriptor is invalid")
            input_frames = input_value["frames"]
            if (
                type(input_value["count"]) is not int
                or input_value["count"] != count
                or not isinstance(input_value["key_mask_sha256"], str)
                or _SHA256.fullmatch(input_value["key_mask_sha256"]) is None
                or input_value["key_mask_sha256"] != _sha256_file(mask_path)
                or not isinstance(input_frames, list)
                or len(input_frames) != len(expected_input_frames)
                or not all(
                    _valid_input_frame_descriptor(item) for item in input_frames
                )
                or input_frames != expected_input_frames
            ):
                raise ValueError("smoke PASS input does not match explicit source files")
            if (
                not isinstance(candidates_value, list)
                or not _valid_smoke_environment(environment_value, environ)
                or not _valid_timings(timings_value)
                or not _valid_cuda(
                    cuda_value,
                    environment_value.get("actual_device")
                    if isinstance(environment_value, dict)
                    else None,
                )
            ):
                raise ValueError("smoke PASS nested report containers are invalid")
            candidate_masks = _candidate_masks_from_report(
                report, report_path, expected_input_frames
            )
        except (OSError, TypeError, ValueError):
            effective_status = "FAIL"
            effective_reason = "smoke PASS evidence failed independent validation"
            candidate_masks = {}
    if (
        not isinstance(candidates_value, list)
        or not isinstance(environment_value, dict)
        or not isinstance(timings_value, dict)
        or not isinstance(cuda_value, dict)
    ):
        effective_status = "FAIL"
        effective_reason = "smoke report containers are invalid"
        candidate_masks = {}
    safe_candidates = candidates_value if isinstance(candidates_value, list) else []
    safe_environment = environment_value if isinstance(environment_value, dict) else {}
    safe_timings = timings_value if isinstance(timings_value, dict) else {}
    safe_cuda = cuda_value if isinstance(cuda_value, dict) else {}
    return {
        "status": effective_status,
        "reason": effective_reason,
        "case_id": case["id"],
        "tag": case["tag"],
        "start": geometry_name,
        "count": count,
        "frame_ids": [
            item["frame_id"]
            for item in input_frames
            if isinstance(item, dict) and type(item.get("frame_id")) is int
        ] if isinstance(input_frames, list) else [],
        "generated_count": len(safe_candidates),
        "timings_ms": safe_timings,
        "stop": report.get("stop"),
        "actual_device": (
            safe_environment.get("actual_device")
            if isinstance(safe_environment.get("actual_device"), str)
            and safe_environment.get("actual_device") in ("cpu", "cuda")
            else None
        ),
        "checkpoint_sha256": (
            safe_environment.get("checkpoint_sha256")
            if isinstance(safe_environment.get("checkpoint_sha256"), str)
            and _SHA256.fullmatch(safe_environment["checkpoint_sha256"]) is not None
            else None
        ),
        "cuda": safe_cuda,
        "_environment": safe_environment,
        "_input_frames": input_frames,
        "_candidate_masks": candidate_masks,
    }


def _read_truth_mask(path_text: str) -> np.ndarray:
    path = Path(path_text)
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ValueError("truth mask cannot be inspected") from exc
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ValueError("truth mask must be a regular non-symlink file")
    mask = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if mask is None or not set(np.unique(mask).tolist()).issubset({0, 255}):
        raise ValueError("truth mask must be a binary PNG")
    return mask


def _valid_stop_topology(value: object, pixel_count: int) -> bool:
    if not isinstance(value, dict) or value.get("status") != "FAIL":
        return False
    reason = value.get("reason")
    if not isinstance(reason, str):
        return False
    base = {"status", "reason"}
    if reason in {"non_binary", "invalid_roi", "empty", "full_image", "hole"}:
        return set(value) == base
    if reason == "multiple_components":
        component_count = value.get("component_count")
        return (
            set(value) == base | {"component_count"}
            and type(component_count) is int
            and 2 <= component_count <= pixel_count
        )
    if reason in {"degenerate", "non_simple_polygon"}:
        vertex_count = value.get("vertex_count")
        lower = 3 if reason == "non_simple_polygon" else 0
        upper = 2048 if reason == "non_simple_polygon" else pixel_count
        return (
            set(value) == base | {"vertex_count"}
            and type(vertex_count) is int
            and lower <= vertex_count <= upper
        )
    if reason == "non_lossless_polygon":
        vertex_count = value.get("vertex_count")
        roundtrip_iou = value.get("roundtrip_iou")
        return (
            set(value) == base | {"vertex_count", "roundtrip_iou"}
            and type(vertex_count) is int
            and 3 <= vertex_count <= 2048
            and type(roundtrip_iou) is float
            and math.isfinite(roundtrip_iou)
            and 0.0 <= roundtrip_iou < 0.99
        )
    return False


def _valid_partial_stop(
    value: object,
    expected_frame: Mapping[str, Any],
) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"kind", "frame_id", "playback_index", "topology"}
        and value.get("kind") == "candidate_topology"
        and isinstance(value.get("frame_id"), int)
        and not isinstance(value.get("frame_id"), bool)
        and isinstance(value.get("playback_index"), int)
        and not isinstance(value.get("playback_index"), bool)
        and value.get("frame_id") == expected_frame["frame_id"]
        and value.get("playback_index") == expected_frame["playback_index"]
        and _valid_stop_topology(
            value.get("topology"),
            int(expected_frame["width"]) * int(expected_frame["height"]),
        )
    )


def _validate_reviewable_run(
    raw: object,
    case: dict[str, Any],
    geometry: str,
    count: int,
    expected_frames: list[dict[str, Any]],
    environment: Mapping[str, Any],
) -> dict[str, Any]:
    """Downgrade a claimed PASS unless its reviewable prefix is self-consistent."""
    if not isinstance(raw, dict):
        return {
            "status": "FAIL",
            "reason": "smoke run returned invalid evidence",
            "case_id": case["id"],
            "tag": case["tag"],
            "start": geometry,
            "count": count,
        }
    run = dict(raw)
    status = run.get("status")
    if not isinstance(status, str) or status not in ("PASS", "NOT RUN", "FAIL"):
        return {
            "status": "FAIL",
            "reason": "smoke run returned invalid evidence",
            "case_id": case["id"],
            "tag": case["tag"],
            "start": geometry,
            "count": count,
        }
    if status != "PASS":
        actual_device = run.get("actual_device")
        checkpoint_sha256 = run.get("checkpoint_sha256")
        return {
            "status": status,
            "reason": _persisted_reason(
                run.get("reason"), "smoke run did not provide a stable reason"
            ),
            "case_id": case["id"],
            "tag": case["tag"],
            "start": geometry,
            "count": count,
            "frame_ids": [],
            "generated_count": 0,
            "timings_ms": {},
            "stop": None,
            "actual_device": (
                actual_device
                if isinstance(actual_device, str)
                and actual_device in ("cpu", "cuda")
                else None
            ),
            "checkpoint_sha256": (
                checkpoint_sha256
                if isinstance(checkpoint_sha256, str)
                and _SHA256.fullmatch(checkpoint_sha256) is not None
                else None
            ),
            "cuda": {},
        }

    reason = ""
    frame_ids = run.get("frame_ids")
    generated_count = run.get("generated_count")
    candidates = run.get("_candidate_masks")
    run_environment = run.get("_environment")
    actual_device = run.get("actual_device")
    checkpoint_sha256 = run.get("checkpoint_sha256")
    expected_input = [_input_frame_descriptor(item) for item in expected_frames]
    expected_frame_ids = [item["frame_id"] for item in expected_input]
    if (
        run.get("case_id") != case["id"]
        or run.get("tag") != case["tag"]
        or run.get("start") != geometry
        or type(run.get("count")) is not int
        or run.get("count") != count
    ):
        reason = "smoke PASS run identity is inconsistent"
    elif (
        not _smoke_environment_matches_preflight(run_environment, environment)
        or not isinstance(run_environment, dict)
        or actual_device != run_environment.get("actual_device")
        or checkpoint_sha256 != environment.get("checkpoint_sha256")
        or not _valid_timings(run.get("timings_ms"))
        or not _valid_cuda(run.get("cuda"), actual_device)
    ):
        reason = "smoke PASS runtime provenance is inconsistent"
    elif (
        not isinstance(frame_ids, list)
        or len(frame_ids) != len(expected_frame_ids)
        or any(type(frame_id) is not int for frame_id in frame_ids)
        or frame_ids != expected_frame_ids
    ):
        reason = "smoke PASS frame identities do not match explicit source files"
    elif (
        not isinstance(run.get("_input_frames"), list)
        or len(run["_input_frames"]) != len(expected_input)
        or not all(
            _valid_input_frame_descriptor(item) for item in run["_input_frames"]
        )
        or run["_input_frames"] != expected_input
    ):
        reason = "smoke PASS input descriptors do not match explicit source files"
    elif (
        isinstance(generated_count, bool)
        or not isinstance(generated_count, int)
        or not 1 <= generated_count <= count
    ):
        reason = "smoke PASS produced no reviewable candidate prefix"
    elif (
        not isinstance(candidates, dict)
        or any(type(frame_id) is not int for frame_id in candidates)
    ):
        reason = "smoke PASS retained no reviewable candidate artifacts"
    else:
        expected_ids = frame_ids[1:1 + generated_count]
        if list(candidates) != expected_ids:
            reason = "smoke PASS candidate prefix identities are inconsistent"
        else:
            for candidate_index, candidate in enumerate(candidates.values(), start=1):
                if (
                    not isinstance(candidate, np.ndarray)
                    or candidate.ndim != 2
                    or candidate.dtype != np.uint8
                    or not set(np.unique(candidate).tolist()).issubset({0, 255})
                ):
                    reason = "smoke PASS candidate artifact is malformed"
                    break
                expected = expected_input[candidate_index]
                shape = (int(candidate.shape[1]), int(candidate.shape[0]))
                if shape != (expected["width"], expected["height"]):
                    reason = "smoke PASS candidate dimensions are inconsistent"
                    break
                ok, encoded = cv2.imencode(".png", candidate)
                if not ok or _topology(
                    encoded.tobytes(),
                    {"roi": [0, 0, shape[0], shape[1]]},
                    shape,
                ).get("status") != "PASS":
                    reason = "smoke PASS candidate is not production-reviewable"
                    break
        stop = run.get("stop")
        if not reason and generated_count == count and stop is not None:
            reason = "smoke PASS stop contradicts its complete candidate prefix"
        elif not reason and generated_count < count and not _valid_partial_stop(
            stop, expected_input[generated_count + 1]
        ):
            reason = "smoke PASS structured stop is inconsistent"

    if reason:
        run["status"] = "FAIL"
        run["reason"] = reason
    return run


def _boundary_error(left: np.ndarray, right: np.ndarray) -> float:
    kernel = np.ones((3, 3), np.uint8)
    left_edge = (left > 0) & (cv2.erode((left > 0).astype(np.uint8), kernel) == 0)
    right_edge = (right > 0) & (cv2.erode((right > 0).astype(np.uint8), kernel) == 0)
    if not left_edge.any() or not right_edge.any():
        return math.inf
    distance_to_right = cv2.distanceTransform((~right_edge).astype(np.uint8), cv2.DIST_L2, 3)
    distance_to_left = cv2.distanceTransform((~left_edge).astype(np.uint8), cv2.DIST_L2, 3)
    return float((distance_to_right[left_edge].mean() + distance_to_left[right_edge].mean()) / 2.0)


def _quality_section(
    cases: list[dict[str, Any]], runs: list[dict[str, Any]]
) -> dict[str, Any]:
    if not cases or any(
        not case["independent_truth"] or case["human_review"] is None
        for case in cases
    ):
        return _not_run(
            "every case needs non-empty independent target masks and human review counts",
            cases=[],
        )
    measured: list[dict[str, Any]] = []
    try:
        for case in cases:
            # One fixed, documented measurement path prevents cherry-picking:
            # evaluate the 30-target Poly-seed run for every case.
            matches = [
                item for item in runs
                if item.get("case_id") == case["id"]
                and item.get("start") == "polygon"
                and item.get("count") == 30
            ]
            if len(matches) != 1:
                raise ValueError(f"case {case['id']} has no unique 30-target Poly run")
            run = matches[0]
            if run.get("status") != "PASS":
                raise ValueError(f"case {case['id']} has no successful 30-target Poly run")
            candidates = run.get("_candidate_masks")
            if not isinstance(candidates, dict):
                raise ValueError(f"case {case['id']} retained no bounded candidate masks")
            frame_ids = run.get("frame_ids")
            generated_count = run.get("generated_count")
            if (
                not isinstance(frame_ids, list)
                or len(frame_ids) != 31
                or any(
                    isinstance(frame_id, bool) or not isinstance(frame_id, int)
                    for frame_id in frame_ids
                )
                or isinstance(generated_count, bool)
                or not isinstance(generated_count, int)
                or not 0 <= generated_count <= 30
            ):
                raise ValueError(f"case {case['id']} has invalid candidate identity evidence")
            expected_candidate_ids = frame_ids[1:1 + generated_count]
            candidate_ids = list(candidates)
            truth_ids = [
                truth_item["frame_id"] for truth_item in case["independent_truth"]
            ]
            if (
                len(candidate_ids) != len(expected_candidate_ids)
                or set(candidate_ids) != set(expected_candidate_ids)
            ):
                raise ValueError(f"case {case['id']} candidate identities are inconsistent")
            if len(truth_ids) != len(candidate_ids) or set(truth_ids) != set(candidate_ids):
                raise ValueError(f"case {case['id']} truth does not exactly cover candidates")
            review = case["human_review"]
            measured_count = len(candidate_ids)
            if (
                review["direct_accept"]
                + review["minor_correction"]
                + review["redraw"]
                != measured_count
            ):
                raise ValueError(f"case {case['id']} human review count is inconsistent")
            if review["silent_drift"] > measured_count:
                raise ValueError(f"case {case['id']} silent drift count is inconsistent")
            stop = run.get("stop")
            if stop is None:
                actual_stop_frame = None
            elif (
                isinstance(stop, dict)
                and isinstance(stop.get("frame_id"), int)
                and not isinstance(stop.get("frame_id"), bool)
                and stop["frame_id"] >= 0
            ):
                actual_stop_frame = stop["frame_id"]
            else:
                raise ValueError(f"case {case['id']} has invalid structured stop evidence")
            if review["stop_frame"] != actual_stop_frame:
                raise ValueError(f"case {case['id']} stop frame is inconsistent")
            frame_metrics: list[dict[str, Any]] = []
            truth_by_id = {
                truth_item["frame_id"]: truth_item
                for truth_item in case["independent_truth"]
            }
            for frame_id in expected_candidate_ids:
                truth_item = truth_by_id[frame_id]
                frame_id = truth_item["frame_id"]
                truth = _read_truth_mask(truth_item["mask"])
                candidate = candidates.get(frame_id)
                if not isinstance(candidate, np.ndarray):
                    raise ValueError(f"case {case['id']} has no candidate for truth frame {frame_id}")
                if candidate.shape != truth.shape:
                    raise ValueError(f"case {case['id']} candidate/truth dimensions differ")
                candidate_foreground = candidate > 0
                truth_foreground = truth > 0
                union = int(np.count_nonzero(candidate_foreground | truth_foreground))
                intersection = int(np.count_nonzero(candidate_foreground & truth_foreground))
                if union == 0:
                    raise ValueError("candidate and truth cannot both be empty")
                boundary = _boundary_error(candidate, truth)
                if not math.isfinite(boundary):
                    raise ValueError("boundary error could not be measured")
                frame_metrics.append({
                    "frame_id": frame_id,
                    "iou": round(intersection / union, 6),
                    "boundary_error_px": round(boundary, 6),
                })
            measured.append({
                "case_id": case["id"],
                "tag": case["tag"],
                "frames": frame_metrics,
                **case["human_review"],
            })
    except (OSError, ValueError) as exc:
        return {
            "status": "FAIL",
            "reason": _persisted_reason(str(exc), "quality evidence is invalid"),
            "cases": [],
        }
    return {"status": "PASS", "reason": "", "cases": measured}


def _efficiency_section(cases: list[dict[str, Any]]) -> dict[str, Any]:
    if not cases or any(case["paired_timing"] is None for case in cases):
        return _not_run(
            "every case needs paired manual and SAM timing for the same scope",
            cases=[],
        )
    measured = [
        {
            "case_id": case["id"],
            "manual_seconds": float(case["paired_timing"]["manual_seconds"]),
            "sam_seconds": float(case["paired_timing"]["sam_seconds"]),
        }
        for case in cases
    ]
    return {"status": "PASS", "reason": "", "cases": measured}


def _cuda_section(runs: list[dict[str, Any]]) -> dict[str, Any]:
    cuda_runs = [run for run in runs if run.get("status") == "PASS" and run.get("actual_device") == "cuda"]
    if not cuda_runs:
        return _not_run("no actual CUDA run was measured")
    propagation: list[float] = []
    for run in cuda_runs:
        cuda = run.get("cuda")
        if not isinstance(cuda, dict):
            return _not_run(
                "actual CUDA per-frame samples and in-flight cancellation are not measured"
            )
        peak_vram = cuda.get("peak_vram_bytes")
        samples = cuda.get("per_frame_propagate_ms")
        cancel_latency = cuda.get("inflight_cancel_latency_ms")
        if (
            isinstance(peak_vram, bool)
            or not isinstance(peak_vram, int)
            or peak_vram < 0
            or not isinstance(samples, list)
            or not samples
            or any(
                isinstance(sample, bool)
                or not isinstance(sample, (int, float))
                or not math.isfinite(float(sample))
                or sample < 0
                for sample in samples
            )
            or isinstance(cancel_latency, bool)
            or not isinstance(cancel_latency, (int, float))
            or not math.isfinite(float(cancel_latency))
            or cancel_latency < 0
        ):
            return _not_run(
                "actual CUDA per-frame samples and in-flight cancellation are not measured"
            )
        propagation.extend(float(sample) for sample in samples)
    propagation.sort()
    p50 = float(np.percentile(propagation, 50))
    p95 = float(np.percentile(propagation, 95))
    return {
        "status": "PASS",
        "reason": "",
        "load_ms": [run["timings_ms"]["load"] for run in cuda_runs],
        "open_ms": [run["timings_ms"]["open"] for run in cuda_runs],
        "propagate_p50_ms": round(p50, 3),
        "propagate_p95_ms": round(p95, 3),
        "peak_vram_bytes": max(run["cuda"]["peak_vram_bytes"] for run in cuda_runs),
        "inflight_cancel_latency_ms": max(
            run["cuda"]["inflight_cancel_latency_ms"] for run in cuda_runs
        ),
    }


def _public_run(run: dict[str, Any]) -> dict[str, Any]:
    public = {key: value for key, value in run.items() if not key.startswith("_")}
    if public.get("status") == "PASS":
        public["reason"] = ""
    else:
        public["reason"] = _persisted_reason(
            public.get("reason"), "smoke run did not provide a stable reason"
        )
    return public


def generate_acceptance_report(
    cases_path: str | Path,
    *,
    environ: Mapping[str, str] | None = None,
    smoke_invoker: Callable[[dict[str, Any], str, int, Mapping[str, str], Path], dict[str, Any]] = _invoke_real_smoke,
    environment_probe: Callable[[Mapping[str, str]], dict[str, Any]] = preflight_environment,
    visible_ui_evidence: str | Path | None = None,
) -> dict[str, Any]:
    allowlist = load_cases(cases_path)
    values = dict(os.environ if environ is None else environ)
    report = _base_report()
    environment = environment_probe(values)
    if not isinstance(environment, dict) or environment.get("status") not in (
        "PASS",
        "NOT RUN",
        "FAIL",
    ):
        environment = {
            "status": "FAIL",
            "reason": "environment probe returned invalid evidence",
        }
    elif environment["status"] == "PASS":
        if _valid_preflight_pass(environment):
            environment = {**environment, "reason": ""}
        else:
            environment = {
                "status": "FAIL",
                "reason": "environment probe returned invalid PASS evidence",
            }
    else:
        environment = {
            **environment,
            "reason": _persisted_reason(
                environment.get("reason"),
                "environment probe did not provide a stable reason",
            ),
        }
    report["environment"] = environment
    cases = allowlist["cases"]
    if report["environment"]["status"] != "PASS":
        report["functional"]["reason"] = "environment preflight is NOT RUN"
        report["functional"]["runtime_smoke"]["reason"] = (
            "environment preflight is NOT RUN"
        )
        return report
    if not cases:
        report["functional"]["reason"] = "explicit case allowlist contains no cases"
        report["functional"]["runtime_smoke"]["reason"] = (
            "explicit case allowlist contains no cases"
        )
        return report
    present_tags = {case["tag"] for case in cases}
    missing_tags = [tag for tag in REQUIRED_TAGS if tag not in present_tags]
    if missing_tags:
        report["functional"]["reason"] = "allowlist is missing required tags: " + ", ".join(missing_tags)
        report["functional"]["runtime_smoke"]["reason"] = report["functional"]["reason"]
        return report
    runs: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="project6-sam-video-acceptance-") as raw_work:
        work = Path(raw_work)
        for case in cases:
            for geometry in ("box", "polygon"):
                for count in (1, 5, 30):
                    try:
                        expected_frames = ordered_frame_sources(case["frames"], count)
                        raw_run = smoke_invoker(case, geometry, count, values, work)
                    except (OSError, RecursionError, TypeError, ValueError):
                        raw_run = {
                            "status": "FAIL",
                            "reason": "explicit source frames could not be validated",
                            "case_id": case["id"],
                            "tag": case["tag"],
                            "start": geometry,
                            "count": count,
                        }
                        expected_frames = []
                    if expected_frames:
                        runs.append(_validate_reviewable_run(
                        raw_run,
                        case,
                        geometry,
                        count,
                        expected_frames,
                        report["environment"],
                    ))
                    else:
                        runs.append(raw_run)
    statuses = {run.get("status") for run in runs}
    runtime_status = "PASS" if statuses == {"PASS"} else "FAIL"
    runtime_smoke = {
        "status": runtime_status,
        "reason": "" if runtime_status == "PASS" else "one or more real smoke runs failed",
        "runs": [_public_run(run) for run in runs],
    }
    visible_ui = _visible_ui_section(
        visible_ui_evidence, cases, report["environment"], runs
    )
    if runtime_status == "FAIL" or visible_ui["status"] == "FAIL":
        functional_status = "FAIL"
    elif runtime_status == "PASS" and visible_ui["status"] == "PASS":
        functional_status = "PASS"
    else:
        functional_status = "NOT RUN"
    report["functional"] = {
        "status": functional_status,
        "reason": (
            "one or more real smoke runs failed"
            if runtime_status == "FAIL"
            else visible_ui["reason"]
        ),
        "runtime_smoke": runtime_smoke,
        "visible_ui": visible_ui,
    }
    report["quality"] = _quality_section(cases, runs)
    report["efficiency"] = _efficiency_section(cases)
    report["cuda_performance"] = _cuda_section(runs)
    return report


def _write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = (
        json.dumps(report, ensure_ascii=False, allow_nan=False, sort_keys=True, indent=2)
        + "\n"
    ).encode("utf-8")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(payload)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--cases",
        type=Path,
        default=Path(__file__).with_name("sam_video_cases.json"),
    )
    parser.add_argument(
        "--visible-ui-evidence",
        type=Path,
        help="absolute path to an explicit bound visible-UI evidence JSON",
    )
    parser.add_argument("--json-out", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        report = generate_acceptance_report(
            args.cases, visible_ui_evidence=args.visible_ui_evidence
        )
        _write_report(args.json_out, report)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"SAM Video acceptance FAIL: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({
        section: report[section]["status"]
        for section in (
            "environment",
            "functional",
            "quality",
            "efficiency",
            "cuda_performance",
        )
    }, ensure_ascii=False, sort_keys=True))
    return 1 if any(
        report[section]["status"] == "FAIL"
        for section in (
            "environment",
            "functional",
            "quality",
            "efficiency",
            "cuda_performance",
        )
    ) else 0


if __name__ == "__main__":
    raise SystemExit(main())
