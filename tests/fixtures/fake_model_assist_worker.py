#!/usr/bin/env python3
"""Deterministic protocol worker used only by local Godot/Python acceptance tests."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python"))

import cv2
import numpy as np

from annotation_data.model_assist_protocol import error_response, loads_line, success_response


def _write(value: dict) -> None:
    sys.stdout.buffer.write((json.dumps(value, separators=(",", ":")) + "\n").encode())
    sys.stdout.buffer.flush()


def _candidate(job: Path, request: dict, mode: str) -> dict:
    directory = job / "candidates"
    directory.mkdir(exist_ok=True)
    name = "candidate-%s.png" % request["request_id"].replace("/", "_")
    path = directory / name
    mask = np.zeros((30, 40), np.uint8)
    mask[3:27, 4:36] = 255
    if mode == "multi_component":
        mask[:] = 0
        mask[3:12, 4:14] = 255
        mask[18:27, 25:36] = 255
    elif mode == "hole":
        mask[10:20, 14:26] = 0
    assert cv2.imwrite(str(path), mask)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if mode == "wrong_hash":
        digest = "0" * 64
    return {"path": path.relative_to(job).as_posix(), "roi": [10, 12, 40, 30], "sha256": digest, "score": 0.875}


def _predict_response(job: Path, request: dict, mode: str) -> dict:
    return success_response(request, {
        "image_sha256": request["context"]["image_sha256"],
        "candidates": [_candidate(job, request, mode)],
    })


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job-dir", required=True)
    parser.add_argument("--config")
    parser.add_argument("--checkpoint")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--session-id", default="standalone-fake")
    args = parser.parse_args()
    job = Path(args.job_dir).resolve(strict=True)
    mode = os.environ.get("MODEL_ASSIST_FAKE_MODE", "ok")
    start_log = os.environ.get("MODEL_ASSIST_FAKE_START_LOG")
    worker_instance = 1
    if start_log:
        start_path = Path(start_log)
        if start_path.exists():
            worker_instance = len(start_path.read_text(encoding="utf-8").splitlines()) + 1
        with Path(start_log).open("a", encoding="utf-8") as handle:
            handle.write(f"{os.getpid()}\n")
    request_log = os.environ.get("MODEL_ASSIST_FAKE_REQUEST_LOG")
    pending: dict | None = None
    set_image_count = 0
    for raw in sys.stdin.buffer:
        try:
            request = loads_line(raw)
        except Exception as exc:
            _write(error_response("invalid", {}, [str(exc)]))
            continue
        op = request["op"]
        if request_log:
            with Path(request_log).open("a", encoding="utf-8") as handle:
                handle.write(json.dumps({"request_id": request["request_id"], "op": op}) + "\n")
        if op == "predict":
            if mode == "crash":
                return 23
            if mode == "hang_once":
                marker = Path(os.environ["MODEL_ASSIST_FAKE_HANG_MARKER"])
                if not marker.exists():
                    marker.write_text("hung", encoding="utf-8")
                    time.sleep(3600)
            if mode == "delay":
                time.sleep(1.0)
            if mode == "malformed":
                sys.stdout.buffer.write(b"{malformed\n")
                sys.stdout.buffer.flush()
                continue
            if mode == "duplicate":
                response = _predict_response(job, request, mode)
                raw = json.dumps(response, separators=(",", ":"))
                raw = raw.replace('{"protocol":', '{"protocol":"model-assist-v1","protocol":', 1)
                sys.stdout.buffer.write((raw + "\n").encode())
                sys.stdout.buffer.flush()
                continue
            if mode == "oversize":
                sys.stdout.buffer.write(b"x" * (1024 * 1024 + 1) + b"\n")
                sys.stdout.buffer.flush()
                continue
            response = _predict_response(job, request, mode)
            if mode == "out_of_order" and worker_instance == 1 and pending is None:
                pending = response
                continue
            _write(response)
            if mode == "out_of_order" and pending is not None:
                _write(pending)
                pending = None
        elif op == "set_image":
            set_image_count += 1
            if mode == "delay_second_image" and set_image_count == 2:
                time.sleep(1.0)
            if mode == "hang_second_image" and set_image_count == 2:
                time.sleep(3600)
            image = request["data"]["image"]
            _write(success_response(request, {
                "image_sha256": image["sha256"], "width": image["width"],
                "height": image["height"], "cached": False,
            }))
        elif op == "hello":
            if mode == "delay_hello":
                time.sleep(1.0)
            checkpoint_digest = "f" * 64
            if args.checkpoint and Path(args.checkpoint).is_file():
                checkpoint_digest = hashlib.sha256(Path(args.checkpoint).read_bytes()).hexdigest()
            _write(success_response(request, {
                "backend": "fake-model-assist", "persistent": True,
                "device": args.device if args.device in {"cpu", "cuda"} else "cpu",
                "checkpoint_sha256": checkpoint_digest,
                "session_id": args.session_id,
                "pid": os.getpid(),
            }))
        elif op == "cancel":
            _write(success_response(request, {
                "target_request_id": request["data"]["target_request_id"], "cancelled": True,
            }))
        else:
            if pending is not None:
                _write(pending)
            _write(success_response(request, {}))
            return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
