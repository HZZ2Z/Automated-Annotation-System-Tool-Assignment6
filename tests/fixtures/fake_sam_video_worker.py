#!/usr/bin/env python3
"""External process boundary fixture; validates real sam-video-v1 requests.

No SAM dependency is loaded. Synthetic PNG outputs exercise the Godot service's
real file, process, protocol, geometry and stale-result boundaries.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import time
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))
from annotation_data.sam_video_protocol import loads_line, success_response


def png(width: int, height: int, pixels: bytes) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    scan = b"".join(b"\0" + pixels[row * width:(row + 1) * width] for row in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(scan)) + chunk(b"IEND", b"")


def main() -> None:
    parser = argparse.ArgumentParser()
    for name in ("job-dir", "config", "checkpoint", "device", "session-id"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    root = Path(args.job_dir)
    mode = os.environ.get("SAM_VIDEO_FAKE_MODE", "ok")
    bound = None
    frames = []
    phase = "hello"
    for line in sys.stdin.buffer:
        request = loads_line(line)
        op, ctx = request["op"], request["context"]
        assert ctx["session_id"] == args.session_id and ctx["requested_device"] == args.device
        if op not in {"hello", "open_batch", "shutdown", "reset_batch"}:
            assert bound == ctx
        if mode == "hang_" + op:
            time.sleep(30)
        if op == "hello":
            assert phase == "hello"
            data = {"backend": "sam2-video-predictor", "persistent": True, "device": "cpu", "checkpoint_sha256": hashlib.sha256(Path(args.checkpoint).read_bytes()).hexdigest(), "session_id": args.session_id, "pid": os.getpid()}
            if mode == "hello_pid": data["pid"] += 1
            if mode == "hello_session": data["session_id"] = "wrong"
            phase = "open_batch"
        elif op == "open_batch":
            assert phase == "open_batch"
            frames = request["data"]["frames"]
            assert len(frames) <= 31
            for frame in frames:
                assert hashlib.sha256((root / frame["path"]).read_bytes()).hexdigest() == frame["sha256"]
            bound = ctx
            data = {"batch_serial": 1, "frame_count": len(frames)}
            phase = "add_mask"
        elif op == "add_mask":
            assert phase == "add_mask"
            mask = request["data"]["mask"]
            assert mask["roi"] == [0, 0, frames[0]["width"], frames[0]["height"]]
            assert hashlib.sha256((root / mask["path"]).read_bytes()).hexdigest() == mask["sha256"]
            data = {"local_index": 0, "object_id": 1}
            phase = "propagate"
        elif op == "propagate":
            assert phase == "propagate"
            if mode == "crash": os._exit(7)
            if mode == "eof": return
            if mode == "delay": time.sleep(0.12)
            output = root / "outputs"
            output.mkdir(exist_ok=True)
            masks = []
            for index, frame in enumerate(frames[1:], 1):
                bits = bytes([255]) * 12
                width, height = 4, 3
                if mode == "topology" and index == 2:
                    width, height = 7, 3
                    bits = bytes([255, 255, 0, 0, 0, 255, 255]) * 3
                if mode == "hole" and index == 2:
                    width, height = 3, 3
                    bits = bytes([255, 255, 255, 255, 0, 255, 255, 255, 255])
                if mode == "empty" and index == 2: bits = bytes(12)
                if mode == "full" and index == 2:
                    width, height = frame["width"], frame["height"]
                    bits = bytes([255]) * (width * height)
                if mode == "binary" and index == 2: bits = bytes([127]) * 12
                path = output / f"mask-{index}.png"
                path.write_bytes(png(width, height, bits))
                descriptor = {"local_index": index, "playback_index": frame["playback_index"], "frame_id": frame["frame_id"], "object_id": 1, "path": path.relative_to(root).as_posix(), "roi": [10, 12, width, height], "score": 0.8, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                if index == 2:
                    if mode == "full": descriptor["roi"] = [0, 0, width, height]
                    if mode == "traversal": descriptor["path"] = "../outside.png"
                    if mode == "hash": descriptor["sha256"] = "0" * 64
                    if mode == "size": descriptor["roi"] = [10, 12, 5, 3]
                    if mode == "roi": descriptor["roi"] = [-1, 12, 4, 3]
                    if mode == "wrong_frame": descriptor["frame_id"] += 1
                    if mode == "bool_identity": descriptor["object_id"] = True
                    if mode == "linked_output":
                        saved = root / "saved.png"
                        path.rename(saved)
                        path.symlink_to(saved)
                masks.append(descriptor)
            if mode == "linked_inputs":
                inputs = root / "inputs"
                saved = root / "saved-inputs"
                inputs.rename(saved)
                inputs.symlink_to(saved, target_is_directory=True)
            if mode == "extra_mask": masks.append(masks[-1])
            data = {"masks": masks}
            phase = "reset_batch"
        elif op == "reset_batch":
            assert phase == "reset_batch"
            if mode == "replace_reset":
                replacement = root / "outputs" / "replacement.png"
                replacement.write_bytes(png(4, 3, bytes([0]) * 12))
                replacement.replace(root / "outputs" / "mask-1.png")
            data = {"reset": True}
            bound = None
            phase = "open_batch"
        elif op == "cancel":
            data = {"cancelled": True, "target_request_id": request["data"]["target_request_id"]}
            bound = None
        else:
            data = {}
        response = success_response(request, data)
        if op == "propagate":
            if mode == "protocol": response["protocol"] = "sam-assist-v1"
            if mode == "request_id": response["request_id"] = "wrong"
            if mode == "context": response["context"]["review_sha256"] = "c" * 64
            if mode == "context_time": response["context"]["key_time_s"] = 0.23333333333333336
            if mode == "context_time_presence": response["context"]["targets"][1]["time_s"] = 0.0
            if mode == "extra": response["unexpected"] = True
            if mode == "malformed": print("{broken", flush=True); continue
            if mode == "overlong": print("x" * 1048577, flush=True); continue
        raw = json.dumps(response, separators=(",", ":"))
        if mode == "duplicate" and op == "propagate": raw = raw.replace('"ok":true', '"ok":true,"ok":true')
        print(raw, flush=True)
        if op == "shutdown": return


if __name__ == "__main__":
    main()
