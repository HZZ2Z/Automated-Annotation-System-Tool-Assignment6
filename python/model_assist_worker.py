#!/usr/bin/env python3
"""Persistent JSONL worker for the official SAM 2 image predictor."""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, BinaryIO

from annotation_data.model_assist_backend import ModelAssistBackend
from annotation_data.model_assist_protocol import (
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
    match = re.search(rb'"request_id"\s*:\s*"([^"\\\r\n]{1,128})"', raw[:4096])
    if match is None:
        return "invalid"
    return match.group(1).decode("utf-8", errors="replace") or "invalid"


def _dispatch(
    backend: Any,
    request: dict[str, Any],
    *,
    service_session_id: str = "",
) -> tuple[dict[str, Any], bool]:
    op = request["op"]
    data = request["data"]
    with redirect_stdout(sys.stderr):
        if op == "hello":
            result = backend.hello()
            if service_session_id:
                result = {
                    **result,
                    "session_id": service_session_id,
                    "pid": os.getpid(),
                }
        elif op == "set_image":
            image = data["image"]
            result = backend.set_image(
                image["path"], image["sha256"], width=image["width"], height=image["height"]
            )
        elif op == "predict":
            result = backend.predict(
                points=data["points"], labels=data["labels"], box=data["box"],
                initial_mask=data["initial_mask"],
            )
        elif op == "cancel":
            result = backend.cancel(data["target_request_id"])
        else:
            backend.shutdown()
            result = {}
    return success_response(request, result), op == "shutdown"


def run_loop(
    backend: Any,
    source: BinaryIO,
    output: BinaryIO,
    *,
    service_session_id: str = "",
) -> int:
    """Serve bounded requests until shutdown or clean EOF."""
    try:
        while True:
            raw = source.readline(MAX_LINE_BYTES + 1)
            if raw == b"":
                return 0
            request: dict[str, Any] | None = None
            try:
                request = loads_line(raw)
                response, should_stop = _dispatch(
                    backend, request, service_session_id=service_session_id
                )
            except Exception as exc:
                request_id = request["request_id"] if request is not None else _best_effort_request_id(raw)
                context = request["context"] if request is not None else {}
                response = error_response(request_id, context, [str(exc) or exc.__class__.__name__])
                should_stop = False
            _write(output, response)
            if should_stop:
                return 0
    finally:
        with redirect_stdout(sys.stderr):
            backend.shutdown()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the Project6 model-assist SAM 2 JSONL worker.")
    parser.add_argument("--job-dir", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--device", choices=("auto", "cpu", "cuda"), default="auto")
    parser.add_argument("--session-id", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        backend = ModelAssistBackend(
            Path(args.job_dir), config_path=args.config,
            checkpoint_path=args.checkpoint, device=args.device,
        )
    except Exception as exc:
        print(f"model assist worker startup failed: {exc}", file=sys.stderr)
        return 2
    return run_loop(
        backend,
        sys.stdin.buffer,
        sys.stdout.buffer,
        service_session_id=args.session_id,
    )


if __name__ == "__main__":
    raise SystemExit(main())
