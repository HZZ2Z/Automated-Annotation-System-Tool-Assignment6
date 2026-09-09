#!/usr/bin/env python3
"""Persistent strict-JSONL worker for an optional SAM batch backend.

This module intentionally imports neither Torch nor SAM.  A backend factory is
provided at runtime so the light-weight protocol worker remains usable in the
project Python environment and the model runtime stays optional.
"""
from __future__ import annotations

import argparse
import contextlib
import importlib
import inspect
from pathlib import Path
import stat
import sys
from typing import Any, BinaryIO


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from annotation_data.sam_batch_protocol import SamBatchRequest, encode_response, parse_request


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ValueError(message)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = Parser(description=__doc__)
    parser.add_argument("--backend", required=True, metavar="MODULE:FACTORY")
    parser.add_argument("--job-dir", required=True, type=Path, metavar="DIR")
    return parser.parse_args(argv)


def _resolve_job_dir(value: Path) -> Path:
    try:
        resolved = value.resolve(strict=True)
    except OSError as exc:
        raise ValueError(f"job directory cannot be resolved: {exc}") from exc
    if not stat.S_ISDIR(resolved.stat().st_mode):
        raise ValueError("job directory must be a directory")
    return resolved


def _load_factory(specification: str):
    module_name, separator, factory_name = specification.partition(":")
    if not separator or not module_name or not factory_name or ":" in factory_name:
        raise ValueError("backend must use MODULE:FACTORY")
    try:
        with contextlib.redirect_stdout(sys.stderr):
            module = importlib.import_module(module_name)
        factory = getattr(module, factory_name)
    except (ImportError, AttributeError) as exc:
        raise ValueError(f"cannot load backend factory {specification}: {exc}") from exc
    if not callable(factory):
        raise ValueError("backend factory must be callable")
    return factory


def _create_backend(factory: Any, job_dir: Path) -> Any:
    try:
        signature = inspect.signature(factory)
    except (TypeError, ValueError):
        signature = None
    accepts_job_dir = signature is None or "job_dir" in signature.parameters or any(
        parameter.kind is inspect.Parameter.VAR_KEYWORD for parameter in (signature.parameters.values() if signature else ())
    )
    backend = None
    try:
        with contextlib.redirect_stdout(sys.stderr):
            backend = factory(job_dir=job_dir) if accepts_job_dir else factory()
        for method in ("hello", "open_batch", "propagate", "reanchor", "close"):
            if not callable(getattr(backend, method, None)):
                raise ValueError(f"backend is missing {method}()")
        return backend
    except Exception:
        if backend is not None and callable(getattr(backend, "close", None)):
            try:
                with contextlib.redirect_stdout(sys.stderr):
                    backend.close()
            except Exception as exc:
                print(f"sam-batch-worker: partial backend close failed: {exc}", file=sys.stderr)
        raise


def _recover_request_id(line: bytes) -> int | None:
    """Recover only an unambiguous positive ID from malformed JSON input."""
    if not isinstance(line, bytes) or not line.endswith(b"\n") or line.count(b"\n") != 1:
        return None
    value = line[:-1]
    depth = 0
    index = 0
    recovered: int | None = None
    seen = 0
    while index < len(value):
        token = value[index]
        if token == 0x22:  # A JSON string; scan without recursively parsing nested data.
            start = index
            index += 1
            escaped = False
            while index < len(value):
                current = value[index]
                index += 1
                if escaped:
                    escaped = False
                elif current == 0x5C:
                    escaped = True
                elif current == 0x22:
                    break
            else:
                return None
            if depth != 1 or value[start:index] != b'"request_id"':
                continue
            cursor = index
            while cursor < len(value) and value[cursor] in b" \t\r":
                cursor += 1
            if cursor >= len(value) or value[cursor] != 0x3A:
                continue
            cursor += 1
            while cursor < len(value) and value[cursor] in b" \t\r":
                cursor += 1
            number_start = cursor
            while cursor < len(value) and 0x30 <= value[cursor] <= 0x39:
                cursor += 1
            if number_start == cursor or value[number_start] == 0x30:
                return None
            if cursor < len(value) and value[cursor] not in b" \t\r,}":
                return None
            if cursor - number_start > 18:
                return None
            try:
                candidate = int(value[number_start:cursor])
            except ValueError:
                return None
            seen += 1
            if seen > 1:
                return None
            recovered = candidate
            continue
        if token in (0x7B, 0x5B):
            depth += 1
        elif token in (0x7D, 0x5D):
            depth -= 1
            if depth < 0:
                return None
        index += 1
    return recovered if depth == 0 and seen == 1 else None


def _backend_call(backend: Any, method: str, *args: Any) -> dict[str, Any]:
    with contextlib.redirect_stdout(sys.stderr):
        result = getattr(backend, method)(*args)
    if not isinstance(result, dict):
        raise ValueError(f"backend {method}() must return an object")
    return result


def _dispatch(backend: Any, request: SamBatchRequest, batch_open: bool) -> tuple[dict[str, Any], bool, bool]:
    if request.op == "hello":
        return _backend_call(backend, "hello"), batch_open, False
    if request.op == "open_batch":
        data = request.data
        return _backend_call(backend, "open_batch", data["frames"], data["key_index"], data["region"]), True, False
    if request.op == "shutdown":
        return {}, batch_open, True
    if not batch_open:
        raise ValueError(f"{request.op} requires open_batch first")
    if request.op == "propagate":
        return _backend_call(backend, "propagate", request.context), batch_open, False
    data = request.data
    return _backend_call(
        backend, "reanchor", data["frame_index"], data["positive_points"], data["negative_points"],
        data.get("box"), data["prompt_revision"],
    ), batch_open, False


def _write_response(output: BinaryIO, request_id: int, ok: bool, context: dict[str, Any], data: dict[str, Any], errors: list[str]) -> None:
    output.write(encode_response(request_id, ok, context, data, errors))
    output.flush()


def run(input_stream: BinaryIO, output_stream: BinaryIO, backend: Any, job_dir: Path) -> int:
    """Serve one backend serially until shutdown or EOF, always flushing replies."""
    last_request_id = 0
    batch_open = False
    for line in input_stream:
        try:
            request = parse_request(line, job_dir=job_dir)
        except (ValueError, OverflowError, RecursionError) as exc:
            request_id = _recover_request_id(line)
            if request_id is not None:
                if request_id <= last_request_id:
                    _write_response(output_stream, request_id, False, {}, {}, ["request_id must be strictly increasing"])
                else:
                    last_request_id = request_id
                    _write_response(output_stream, request_id, False, {}, {}, [str(exc)])
            continue
        if request.request_id <= last_request_id:
            _write_response(output_stream, request.request_id, False, request.context, {}, ["request_id must be strictly increasing"])
            continue
        last_request_id = request.request_id
        try:
            data, batch_open, should_stop = _dispatch(backend, request, batch_open)
            _write_response(output_stream, request.request_id, True, request.context, data, [])
        except Exception as exc:
            _write_response(output_stream, request.request_id, False, request.context, {}, [str(exc)])
            should_stop = False
        if should_stop:
            return 0
    return 0


def main(argv: list[str] | None = None, *, input_stream: BinaryIO | None = None, output_stream: BinaryIO | None = None) -> int:
    backend = None
    try:
        args = parse_args(argv)
        job_dir = _resolve_job_dir(args.job_dir)
        factory = _load_factory(args.backend)
        backend = _create_backend(factory, job_dir)
        return run(input_stream or sys.stdin.buffer, output_stream or sys.stdout.buffer, backend, job_dir)
    except (ValueError, OSError) as exc:
        print(f"sam-batch-worker: {exc}", file=sys.stderr)
        return 2
    finally:
        if backend is not None:
            try:
                with contextlib.redirect_stdout(sys.stderr):
                    backend.close()
            except Exception as exc:  # Closing must not add non-protocol stdout or mask the loop result.
                print(f"sam-batch-worker: backend close failed: {exc}", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
