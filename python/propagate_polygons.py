"""Run bounded polygon propagation against immutable PNG snapshots."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

from annotation_data.polygon_propagation import propagate


class OutputCollision(ValueError):
    """错误结果也不能写入受保护输入路径。"""


def _check_output_paths(args, request=None):
    named = [args.request, args.result, args.cancel_file, args.progress_file]
    resolved = [path.resolve() for path in named]
    if len(set(resolved)) != len(resolved):
        raise OutputCollision("request, result, cancel and progress paths must be distinct")
    if isinstance(request, dict) and isinstance(request.get("frames"), list):
        for frame in request["frames"]:
            if isinstance(frame, dict) and isinstance(frame.get("image_path"), str):
                image = Path(frame["image_path"]).resolve()
                if image in (resolved[1], resolved[3]):
                    raise OutputCollision("result or progress path aliases an input image")


def atomic_json(path: Path, payload: dict) -> None:
    """同目录临时文件写完后替换，调用方只能观察到完整 JSON。"""
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=f".{path.name}.", suffix=".tmp", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(payload, stream, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _reject_constant(value):
    raise ValueError(f"non-finite JSON number: {value}")


def _unique_fields(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", required=True, type=Path)
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--cancel-file", required=True, type=Path)
    parser.add_argument("--progress-file", required=True, type=Path)
    try:
        args = parser.parse_args(argv)
    except SystemExit as error:
        # argparse 的用法错误默认退出 2；本协议统一使用失败码 1，help 仍为 0。
        return 0 if error.code == 0 else 1
    try:
        # 必须在进度回调和最终结果写入之前检查，原子替换本身不保护输入文件。
        _check_output_paths(args)
        if not args.request.is_file():
            raise ValueError("request JSON must be a regular file")
        if args.request.stat().st_size > 8 * 1024 * 1024:
            raise ValueError("request JSON exceeds the 8 MiB limit")
        request = json.loads(args.request.read_text(encoding="utf-8"), parse_constant=_reject_constant, object_pairs_hook=_unique_fields)
        _check_output_paths(args, request)
        if args.cancel_file.exists():
            result = {"schema_version": 1, "success": False, "cancelled": True, "error": "polygon analysis cancelled"}
        else:
            result = propagate(request, cancelled=args.cancel_file.exists,
                               progress=lambda payload: atomic_json(args.progress_file, payload))
    except OutputCollision as error:
        print(f"Cannot write polygon output: {error}", file=sys.stderr)
        return 1
    except (ValueError, OSError, UnicodeError, RecursionError) as error:
        is_cancelled = args.cancel_file.exists()
        result = {"schema_version": 1, "success": False, "cancelled": is_cancelled,
                  "error": "polygon analysis cancelled" if is_cancelled else str(error)}
    try:
        atomic_json(args.result, result)
    except (ValueError, OSError) as error:
        print(f"Cannot write polygon result: {error}", file=sys.stderr)
        return 1
    return 130 if result["cancelled"] else (0 if result["success"] else 1)


if __name__ == "__main__":
    raise SystemExit(main())
