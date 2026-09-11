#!/usr/bin/env python3
"""Persistent JSONL worker for the official SAM 2 video predictor."""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
from copy import deepcopy
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, BinaryIO

from annotation_data.sam_video_backend import SamVideoBackend
from annotation_data.sam_video_protocol import (
    MAX_LINE_BYTES,
    error_response,
    loads_line,
    success_response,
)


def _write(output: BinaryIO, response: dict[str, Any]) -> None:
    raw = (json.dumps(
        response, ensure_ascii=False, allow_nan=False, separators=(",", ":")
    ) + "\n").encode("utf-8")
    if len(raw) > MAX_LINE_BYTES:
        raise ValueError("response line exceeds one MiB")
    output.write(raw)
    output.flush()


def _best_effort_request_id(raw: bytes) -> str:
    match = re.search(rb'"request_id"\s*:\s*"([^"\\\x00-\x1f\x7f]{1,128})"', raw[:4096])
    if match is None:
        return "invalid"
    return match.group(1).decode("utf-8", errors="replace") or "invalid"


def _safe_error(exc: Exception) -> str:
    message = str(exc) or exc.__class__.__name__
    cleaned = "".join(character if ord(character) >= 32 and ord(character) != 127 else " " for character in message)
    return cleaned[:512] or "worker request failed"


def _read_request_line(source: BinaryIO) -> bytes:
    """Read one physical line and discard its tail when it exceeds the bound."""
    raw = source.readline(MAX_LINE_BYTES + 1)
    if len(raw) <= MAX_LINE_BYTES or raw.endswith(b"\n"):
        return raw
    while True:
        remainder = source.readline(MAX_LINE_BYTES + 1)
        if remainder == b"" or remainder.endswith(b"\n"):
            return raw


class _WorkerState:
    def __init__(self, service_session_id: str) -> None:
        self.service_session_id = service_session_id
        self.active_context: dict[str, Any] | None = None


def _verify_configured_context(
    backend: SamVideoBackend,
    context: dict[str, Any],
    state: _WorkerState,
) -> None:
    if (
        state.service_session_id
        and context["session_id"] != state.service_session_id
    ):
        raise RuntimeError("request context session does not match the worker session")
    configured_device = backend.device
    if context["requested_device"] != configured_device:
        raise RuntimeError("request context device does not match the worker device")


def _require_bound_context(
    context: dict[str, Any], state: _WorkerState
) -> None:
    if state.active_context is None:
        raise RuntimeError("open_batch must bind context before this operation")
    if context != state.active_context:
        raise RuntimeError("request context does not match the active batch context")


def _invalidate_batch(backend: SamVideoBackend, state: _WorkerState) -> None:
    state.active_context = None
    try:
        with redirect_stdout(sys.stderr):
            backend.reset_batch()
    except Exception:
        # Backend reset clears owned state references before calling the
        # predictor, so even a predictor reset failure cannot permit reuse.
        pass


def _dispatch(
    backend: SamVideoBackend,
    request: dict[str, Any],
    *,
    state: _WorkerState,
) -> tuple[dict[str, Any], bool]:
    op = request["op"]
    context = request["context"]
    data = request["data"]
    _verify_configured_context(backend, context, state)
    with redirect_stdout(sys.stderr):
        if op == "hello":
            result = backend.hello()
            requested_device = context["requested_device"]
            if requested_device != "auto" and result.get("device") != requested_device:
                raise RuntimeError("loaded predictor device does not match request context")
            result = {
                **result,
                "session_id": state.service_session_id,
                "pid": os.getpid(),
            }
        elif op == "open_batch":
            result = backend.open_batch(data["frames"])
            state.active_context = deepcopy(context)
        elif op == "add_mask":
            _require_bound_context(context, state)
            result = backend.add_mask(data["mask"], data["object_id"])
        elif op == "propagate":
            _require_bound_context(context, state)
            result = backend.propagate(data["count"], data["object_id"])
        elif op == "cancel":
            _require_bound_context(context, state)
            result = backend.cancel(data["target_request_id"])
            backend.reset_batch()
            state.active_context = None
        elif op == "reset_batch":
            if state.active_context is not None:
                _require_bound_context(context, state)
            result = backend.reset_batch()
            state.active_context = None
        else:
            if state.active_context is not None:
                _require_bound_context(context, state)
            backend.shutdown()
            state.active_context = None
            result = {}
    return success_response(request, result), op == "shutdown"


def run_loop(
    backend: SamVideoBackend,
    source: BinaryIO,
    output: BinaryIO,
    *,
    service_session_id: str = "",
) -> int:
    """Serve one bounded response per request until shutdown or clean EOF."""
    state = _WorkerState(service_session_id)
    try:
        while True:
            raw = _read_request_line(source)
            if raw == b"":
                return 0
            request: dict[str, Any] | None = None
            try:
                request = loads_line(raw)
                response, should_stop = _dispatch(
                    backend, request, state=state
                )
            except Exception as exc:
                _invalidate_batch(backend, state)
                request_id = (
                    request["request_id"] if request is not None else _best_effort_request_id(raw)
                )
                context = request["context"] if request is not None else {}
                response = error_response(request_id, context, [_safe_error(exc)])
                should_stop = False
            _write(output, response)
            if should_stop:
                return 0
    finally:
        with redirect_stdout(sys.stderr):
            backend.shutdown()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the Project6 SAM 2 video JSONL worker."
    )
    parser.add_argument("--job-dir", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--device", choices=("auto", "cpu", "cuda"), default="auto")
    parser.add_argument("--session-id", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        backend = SamVideoBackend(
            Path(args.job_dir),
            config_path=args.config,
            checkpoint_path=args.checkpoint,
            device=args.device,
        )
    except Exception as exc:
        print(f"SAM video worker startup failed: {_safe_error(exc)}", file=sys.stderr)
        return 2
    return run_loop(
        backend,
        sys.stdin.buffer,
        sys.stdout.buffer,
        service_session_id=args.session_id,
    )


if __name__ == "__main__":
    raise SystemExit(main())
