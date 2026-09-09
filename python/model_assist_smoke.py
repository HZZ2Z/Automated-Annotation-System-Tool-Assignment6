#!/usr/bin/env python3
"""Run one explicit, non-downloading Model Assist request against real SAM 2.

The harness itself runs in the Project6 environment.  ``--python`` selects the
external interpreter that owns Torch/SAM 2 and launches the production JSONL
worker.  Every artifact is created below a new output directory; existing
paths are never reused or overwritten.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import select
import stat
import struct
import subprocess
import sys
import time
from typing import Any, BinaryIO, Callable
import uuid
import zlib

import cv2
import numpy as np

from annotation_data.model_assist_protocol import (
    MAX_LINE_BYTES,
    PROTOCOL,
    validate_request,
    validate_response,
)


MAX_INPUT_BYTES = 64 * 1024 * 1024
DEFAULT_LOAD_TIMEOUT_SECONDS = 180.0
DEFAULT_PREDICT_TIMEOUT_SECONDS = 60.0
_WORKER = Path(__file__).with_name("model_assist_worker.py")
_REPO_ROOT = Path(__file__).resolve().parents[1]


class SmokeFailure(RuntimeError):
    """Expected acceptance failure with a concise evidence message."""


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _regular_file(raw_path: str | Path, label: str, *, executable: bool = False) -> Path:
    path = Path(raw_path)
    if not path.is_absolute():
        raise ValueError(f"{label} must be an absolute path")
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ValueError(f"{label} cannot be inspected: {exc}") from exc
    if executable:
        # Keep the explicit Conda/venv launcher path: resolving its normal
        # symlink can bypass pyvenv.cfg and silently select the base runtime.
        if not path.is_file():
            raise ValueError(f"{label} must point to a regular executable file")
        normalized = Path(os.path.abspath(path))
    elif stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"{label} must be a regular non-symlink file")
    else:
        normalized = path.resolve(strict=True)
    if executable and not os.access(normalized, os.X_OK):
        raise ValueError(f"{label} must be executable")
    return normalized


def png_size(payload: bytes) -> tuple[int, int]:
    """Validate a bounded PNG container and return its IHDR dimensions."""
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("image must be a PNG with a valid signature")
    offset = 8
    image_size: tuple[int, int] | None = None
    saw_data = False
    while offset < len(payload):
        if offset + 12 > len(payload):
            raise ValueError("image PNG has a truncated chunk")
        length = struct.unpack(">I", payload[offset:offset + 4])[0]
        kind = payload[offset + 4:offset + 8]
        end = offset + 12 + length
        if length > MAX_INPUT_BYTES or end > len(payload):
            raise ValueError("image PNG has an invalid chunk length")
        data = payload[offset + 8:offset + 8 + length]
        checksum = struct.unpack(">I", payload[offset + 8 + length:end])[0]
        if checksum != zlib.crc32(kind + data) & 0xFFFFFFFF:
            raise ValueError("image PNG has a chunk checksum mismatch")
        if image_size is None:
            if kind != b"IHDR" or length != 13:
                raise ValueError("image PNG must start with one canonical IHDR chunk")
            width, height = struct.unpack(">II", data[:8])
            if width <= 0 or height <= 0 or width * height > 32 * 1024 * 1024:
                raise ValueError("image PNG dimensions are empty or too large")
            image_size = (width, height)
        elif kind == b"IHDR":
            raise ValueError("image PNG contains more than one IHDR chunk")
        elif kind == b"IDAT":
            saw_data = True
        elif kind == b"IEND":
            if length != 0 or not saw_data or end != len(payload):
                raise ValueError("image PNG has an invalid terminal chunk")
            return image_size
        offset = end
    raise ValueError("image PNG is missing IEND")


def _finite_pair(value: list[float], label: str) -> list[float]:
    if len(value) != 2 or any(not math.isfinite(float(item)) for item in value):
        raise ValueError(f"{label} must contain two finite coordinates")
    return [float(value[0]), float(value[1])]


def normalize_prompts(
    positive: list[list[float]],
    negative: list[list[float]],
    box: list[float] | None,
    width: int,
    height: int,
) -> dict[str, Any]:
    """Validate CLI prompts in original image coordinates."""
    points = [
        *(_finite_pair(value, "positive point") for value in positive),
        *(_finite_pair(value, "negative point") for value in negative),
    ]
    labels = [1] * len(positive) + [0] * len(negative)
    if len(points) > 64:
        raise ValueError("prompts may contain at most 64 points")
    for x, y in points:
        if not 0.0 <= x < width or not 0.0 <= y < height:
            raise ValueError("point coordinates must stay inside image bounds")
    normalized_box: list[float] | None = None
    if box is not None:
        if len(box) != 4 or any(not math.isfinite(float(item)) for item in box):
            raise ValueError("box must contain four finite coordinates")
        normalized_box = [float(item) for item in box]
        x0, y0, x1, y1 = normalized_box
        if not (0.0 <= x0 < x1 <= width and 0.0 <= y0 < y1 <= height):
            raise ValueError("box must be ordered and stay inside image bounds")
    if not points and normalized_box is None:
        points = [[(width - 1) / 2.0, (height - 1) / 2.0]]
        labels = [1]
    return {"points": points, "labels": labels, "box": normalized_box}


def create_job_dir(raw_path: str | Path) -> Path:
    """Create one new evidence/job directory and refuse every collision."""
    path = Path(raw_path)
    candidate = path.resolve(strict=False)
    try:
        repository_relative = candidate.relative_to(_REPO_ROOT)
    except ValueError:
        repository_relative = None
    if repository_relative is not None and (
        len(repository_relative.parts) < 2
        or repository_relative.parts[0] != ".local-acceptance"
    ):
        raise ValueError(
            "repository-local --output-dir must be below the ignored .local-acceptance directory"
        )
    path.mkdir(parents=True, mode=0o700, exist_ok=False)
    resolved = path.resolve(strict=True)
    if path.is_symlink() or not resolved.is_dir():
        raise ValueError("output directory must be a newly created regular directory")
    return resolved


def _write_exclusive(path: Path, payload: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())


def validate_candidate(
    job_dir: Path, descriptor: dict[str, Any], image_size: tuple[int, int]
) -> dict[str, Any]:
    """Independently check each real worker artifact before reporting PASS."""
    if not isinstance(descriptor, dict) or set(descriptor) != {"path", "roi", "sha256", "score"}:
        raise ValueError("candidate descriptor has invalid fields")
    relative = PurePosixPath(descriptor["path"]) if isinstance(descriptor["path"], str) else PurePosixPath("")
    if relative.is_absolute() or relative.suffix.lower() != ".png" or any(
        part in {"", ".", ".."} for part in relative.parts
    ):
        raise ValueError("candidate path must be a traversal-free relative PNG")
    path = job_dir.joinpath(*relative.parts)
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode):
        raise ValueError("candidate must not be a symlink")
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("candidate must be a regular file")
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(job_dir.resolve(strict=True))
    except ValueError as exc:
        raise ValueError("candidate escaped the smoke output directory") from exc
    payload = resolved.read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    if not isinstance(descriptor["sha256"], str) or digest != descriptor["sha256"]:
        raise ValueError("candidate SHA-256 does not match its descriptor")
    decoded_size = png_size(payload)
    mask = cv2.imdecode(np.frombuffer(payload, np.uint8), cv2.IMREAD_GRAYSCALE)
    if mask is None or mask.ndim != 2:
        raise ValueError("candidate PNG cannot be decoded as a mask")
    values = set(np.unique(mask).tolist())
    if not values.issubset({0, 255}):
        raise ValueError("candidate mask must contain only binary 0/255 pixels")
    foreground_pixels = int(np.count_nonzero(mask))
    if foreground_pixels == 0:
        raise ValueError("candidate mask must not be empty")
    roi = descriptor["roi"]
    if (
        not isinstance(roi, list)
        or len(roi) != 4
        or any(isinstance(item, bool) or not isinstance(item, int) for item in roi)
    ):
        raise ValueError("candidate ROI must contain four integers")
    x, y, roi_width, roi_height = roi
    width, height = image_size
    if x < 0 or y < 0 or roi_width <= 0 or roi_height <= 0 or x + roi_width > width or y + roi_height > height:
        raise ValueError("candidate ROI is outside the image")
    if mask.shape != (roi_height, roi_width):
        raise ValueError("candidate mask dimensions do not match its ROI")
    if decoded_size != (roi_width, roi_height):
        raise ValueError("candidate PNG IHDR dimensions do not match its ROI")
    score = descriptor["score"]
    if isinstance(score, bool) or not isinstance(score, (int, float)) or not math.isfinite(float(score)):
        raise ValueError("candidate score must be finite")
    return {
        "path": relative.as_posix(),
        "roi": list(roi),
        "sha256": digest,
        "score": float(score),
        "mask_size": [roi_width, roi_height],
        "foreground_pixels": foreground_pixels,
    }


def _no_duplicate_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate response key: {key}")
        result[key] = value
    return result


class WorkerClient:
    def __init__(self, process: subprocess.Popen[bytes]) -> None:
        if process.stdin is None or process.stdout is None:
            raise ValueError("worker pipes are unavailable")
        self.process = process
        self.source: BinaryIO = process.stdout
        self.sink: BinaryIO = process.stdin
        self.buffer = bytearray()

    def request(self, request: dict[str, Any], timeout_seconds: float) -> dict[str, Any]:
        normalized = validate_request(request)
        raw = (json.dumps(normalized, allow_nan=False, separators=(",", ":")) + "\n").encode("utf-8")
        if len(raw) > MAX_LINE_BYTES:
            raise SmokeFailure("request exceeds the protocol line limit")
        try:
            self.sink.write(raw)
            self.sink.flush()
        except (BrokenPipeError, OSError) as exc:
            raise SmokeFailure(f"worker input closed before {normalized['op']}: {exc}") from exc
        response = self._read_response(timeout_seconds)
        if response["request_id"] != normalized["request_id"]:
            raise SmokeFailure(
                f"worker response id {response['request_id']!r} did not match {normalized['request_id']!r}"
            )
        if response["context"] != normalized["context"]:
            raise SmokeFailure("worker response changed the frozen request context")
        if not response["ok"]:
            raise SmokeFailure("; ".join(response["errors"]))
        return response

    def _read_response(self, timeout_seconds: float) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_seconds
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SmokeFailure(f"worker response timed out after {timeout_seconds:.1f} seconds")
            readable, _, _ = select.select([self.source.fileno()], [], [], remaining)
            if not readable:
                raise SmokeFailure(f"worker response timed out after {timeout_seconds:.1f} seconds")
            chunk = os.read(self.source.fileno(), 64 * 1024)
            if not chunk:
                code = self.process.poll()
                raise SmokeFailure(f"worker stdout closed unexpectedly (exit={code})")
            self.buffer.extend(chunk)
            if len(self.buffer) > MAX_LINE_BYTES:
                raise SmokeFailure("worker response exceeds the protocol line limit")
        raw, _, remainder = self.buffer.partition(b"\n")
        self.buffer = bytearray(remainder)
        try:
            value = json.loads(
                raw.decode("utf-8"),
                object_pairs_hook=_no_duplicate_object,
                parse_constant=lambda token: (_ for _ in ()).throw(ValueError(f"non-finite JSON: {token}")),
            )
            return validate_response(value)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise SmokeFailure(f"worker returned invalid protocol JSON: {exc}") from exc


_PROBE_CODE = r"""
import importlib.metadata as md
import json
import os
import platform
import sys
import cv2
import numpy
import sam2
import torch
import torchvision

def distribution_version(name):
    try:
        return md.version(name)
    except md.PackageNotFoundError:
        return "unknown"

cuda = bool(torch.cuda.is_available())
print(json.dumps({
    "python_executable": sys.executable,
    "python_version": platform.python_version(),
    "torch": str(torch.__version__),
    "torchvision": str(torchvision.__version__),
    "numpy": str(numpy.__version__),
    "opencv": str(cv2.__version__),
    "sam2_distribution": distribution_version("SAM-2"),
    "sam2_package": os.path.realpath(next(iter(sam2.__path__))),
    "cuda_available": cuda,
    "cuda_device": torch.cuda.get_device_name(0) if cuda else None,
}, allow_nan=False, separators=(",", ":")))
"""


def probe_runtime(python: Path, timeout_seconds: float = 60.0) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            [str(python), "-c", _PROBE_CODE],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise SmokeFailure(f"runtime probe timed out after {timeout_seconds:.1f} seconds") from exc
    stdout = completed.stdout[:MAX_LINE_BYTES]
    stderr = completed.stderr[:64 * 1024].decode("utf-8", errors="replace").strip()
    if completed.returncode != 0:
        raise SmokeFailure(
            f"runtime probe failed with exit {completed.returncode}: {stderr or 'no stderr'}"
        )
    try:
        value = json.loads(stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SmokeFailure("runtime probe did not return one JSON object") from exc
    required = {
        "python_executable", "python_version", "torch", "torchvision", "numpy", "opencv",
        "sam2_distribution", "sam2_package", "cuda_available", "cuda_device",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise SmokeFailure("runtime probe returned an unexpected result shape")
    return value


def _context(
    session_id: str, image_sha256: str, *, frame_id: int, playback_index: int, revision: int
) -> dict[str, Any]:
    return {
        "session_id": session_id,
        "frame_id": frame_id,
        "playback_index": playback_index,
        "image_sha256": image_sha256,
        "record_sha256": hashlib.sha256(b"model-assist-smoke-no-record").hexdigest(),
        "selected_region_id": "",
        "prompt_revision": revision,
    }


def _request(request_id: str, op: str, context: dict[str, Any], data: dict[str, Any]) -> dict[str, Any]:
    return {
        "protocol": PROTOCOL,
        "request_id": request_id,
        "op": op,
        "context": context,
        "data": data,
    }


def _write_report(job_dir: Path, report: dict[str, Any]) -> Path:
    path = job_dir / "report.json"
    payload = (json.dumps(report, ensure_ascii=False, allow_nan=False, indent=2) + "\n").encode("utf-8")
    _write_exclusive(path, payload)
    return path


def _parse_numbers(raw: str, count: int, label: str) -> list[float]:
    try:
        values = [float(item.strip()) for item in raw.split(",")]
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{label} must use comma-separated numbers") from exc
    if len(values) != count or any(not math.isfinite(item) for item in values):
        raise argparse.ArgumentTypeError(f"{label} must contain {count} finite numbers")
    return values


def _point(raw: str) -> list[float]:
    return _parse_numbers(raw, 2, "point")


def _box(raw: str) -> list[float]:
    return _parse_numbers(raw, 4, "box")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run one no-download Project6 model-assist-v1 request against official SAM 2."
    )
    parser.add_argument("--python", required=True, help="Absolute external Conda Python path")
    parser.add_argument("--config", required=True, help="Absolute official SAM 2 config path")
    parser.add_argument("--checkpoint", required=True, help="Absolute official SAM 2 checkpoint path")
    parser.add_argument("--image", required=True, help="Absolute local PNG frame path")
    parser.add_argument("--output-dir", required=True, help="New evidence directory; must not exist")
    parser.add_argument("--device", choices=("auto", "cpu", "cuda"), default="auto")
    parser.add_argument("--positive-point", action="append", type=_point, default=[], metavar="X,Y")
    parser.add_argument("--negative-point", action="append", type=_point, default=[], metavar="X,Y")
    parser.add_argument("--box", type=_box, metavar="X0,Y0,X1,Y1")
    parser.add_argument("--frame-id", type=int, default=0)
    parser.add_argument("--playback-index", type=int, default=0)
    parser.add_argument("--load-timeout", type=float, default=DEFAULT_LOAD_TIMEOUT_SECONDS)
    parser.add_argument("--predict-timeout", type=float, default=DEFAULT_PREDICT_TIMEOUT_SECONDS)
    return parser


def run(
    args: argparse.Namespace,
    *,
    runtime_probe: Callable[[Path], dict[str, Any]] = probe_runtime,
    worker_path: Path = _WORKER,
) -> tuple[int, Path]:
    started_wall = datetime.now(timezone.utc)
    started = time.monotonic()
    job_dir = create_job_dir(args.output_dir)
    report: dict[str, Any] = {
        "schema": "project6-model-assist-smoke-v1",
        "status": "FAIL",
        "started_at_utc": started_wall.isoformat(),
        "finished_at_utc": None,
        "elapsed_seconds": None,
        "inputs": {},
        "runtime": None,
        "prompts": None,
        "stages_seconds": {},
        "hello": None,
        "set_image": None,
        "candidates": [],
        "worker_exit_code": None,
        "worker_stderr": "worker.stderr.log",
        "error": None,
    }
    process: subprocess.Popen[bytes] | None = None
    client: WorkerClient | None = None
    report_path = job_dir / "report.json"
    try:
        python = _regular_file(args.python, "--python", executable=True)
        config = _regular_file(args.config, "--config")
        checkpoint = _regular_file(args.checkpoint, "--checkpoint")
        image = _regular_file(args.image, "--image")
        if image.suffix.lower() != ".png":
            raise ValueError("--image must name a PNG frame")
        image_payload = image.read_bytes()
        if len(image_payload) > MAX_INPUT_BYTES:
            raise ValueError("--image exceeds the 64 MiB smoke limit")
        width, height = png_size(image_payload)
        prompts = normalize_prompts(
            args.positive_point, args.negative_point, args.box, width, height
        )
        if args.frame_id < 0 or args.playback_index < 0:
            raise ValueError("frame and playback indices must be nonnegative")
        if args.load_timeout <= 0 or args.predict_timeout <= 0:
            raise ValueError("timeouts must be positive")
        image_sha256 = hashlib.sha256(image_payload).hexdigest()
        _write_exclusive(job_dir / "input.png", image_payload)
        report["inputs"] = {
            "python": str(python),
            "config": str(config),
            "config_sha256": _sha256_file(config),
            "checkpoint": str(checkpoint),
            "checkpoint_sha256": _sha256_file(checkpoint),
            "image": str(image),
            "image_sha256": image_sha256,
            "image_size": [width, height],
            "device_requested": args.device,
            "frame_id": args.frame_id,
            "playback_index": args.playback_index,
        }
        report["prompts"] = prompts

        stage = time.monotonic()
        report["runtime"] = runtime_probe(python)
        report["stages_seconds"]["runtime_probe"] = round(time.monotonic() - stage, 6)

        session_id = "smoke-" + uuid.uuid4().hex
        stderr_path = job_dir / "worker.stderr.log"
        with stderr_path.open("xb") as stderr_handle:
            process = subprocess.Popen(
                [
                    str(python), str(worker_path), "--job-dir", str(job_dir),
                    "--config", str(config), "--checkpoint", str(checkpoint),
                    "--device", args.device, "--session-id", session_id,
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=stderr_handle,
                cwd=str(worker_path.parent.parent),
            )
            client = WorkerClient(process)

            stage = time.monotonic()
            hello = client.request(_request("smoke-1", "hello", {}, {}), args.load_timeout)["data"]
            report["stages_seconds"]["hello_model_load"] = round(time.monotonic() - stage, 6)
            if (
                hello.get("session_id") != session_id
                or hello.get("pid") != process.pid
                or hello.get("checkpoint_sha256") != report["inputs"]["checkpoint_sha256"]
            ):
                raise SmokeFailure("worker hello did not prove session, PID and checkpoint ownership")
            report["hello"] = hello

            base_context = _context(
                session_id, image_sha256, frame_id=args.frame_id,
                playback_index=args.playback_index, revision=0,
            )
            descriptor = {
                "path": "input.png", "sha256": image_sha256,
                "width": width, "height": height,
            }
            stage = time.monotonic()
            image_result = client.request(
                _request("smoke-2", "set_image", base_context, {"image": descriptor}),
                args.load_timeout,
            )["data"]
            report["stages_seconds"]["image_embedding"] = round(time.monotonic() - stage, 6)
            if (
                image_result.get("image_sha256") != image_sha256
                or image_result.get("width") != width
                or image_result.get("height") != height
            ):
                raise SmokeFailure("set_image response did not match the frozen input image")
            report["set_image"] = image_result

            predict_context = {**base_context, "prompt_revision": 1}
            stage = time.monotonic()
            prediction = client.request(
                _request("smoke-3", "predict", predict_context, {
                    **prompts, "initial_mask": None,
                }),
                args.predict_timeout,
            )["data"]
            report["stages_seconds"]["prediction"] = round(time.monotonic() - stage, 6)
            if prediction.get("image_sha256") != image_sha256:
                raise SmokeFailure("prediction response did not preserve the frozen image digest")
            candidates = prediction.get("candidates")
            if not isinstance(candidates, list) or not 1 <= len(candidates) <= 3:
                raise SmokeFailure("prediction must return from one to three candidates")
            report["candidates"] = [
                validate_candidate(job_dir, item, (width, height)) for item in candidates
            ]

            shutdown = client.request(_request("smoke-4", "shutdown", {}, {}), 10.0)
            if shutdown["data"] != {}:
                raise SmokeFailure("shutdown response data must be empty")
            process.wait(timeout=10.0)
            report["worker_exit_code"] = process.returncode
            if process.returncode != 0:
                raise SmokeFailure(f"worker exited with {process.returncode} after shutdown")

        report["status"] = "PASS"
        return_code = 0
    except Exception as exc:
        report["error"] = str(exc) or exc.__class__.__name__
        return_code = 1
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5.0)
        if process is not None:
            report["worker_exit_code"] = process.returncode
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        report["elapsed_seconds"] = round(time.monotonic() - started, 6)
        if not report_path.exists():
            _write_report(job_dir, report)
    return return_code, report_path


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    code, report_path = run(args)
    status = "PASS" if code == 0 else "FAIL"
    print(f"Model Assist smoke {status}: {report_path}")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
