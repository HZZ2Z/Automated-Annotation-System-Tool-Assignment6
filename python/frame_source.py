"""Command-line entry point for video normalization."""

import argparse
import json
import os
from pathlib import Path
import tempfile
from typing import Any, Sequence

from annotool.frame_source import decode_video


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Normalize a video into PNG frames and a manifest.")
    parser.add_argument("input", type=Path, help="video file to decode")
    parser.add_argument("--output", type=Path, required=True, help="new normalized output directory")
    parser.add_argument("--result-file", type=Path, help="JSON status file for process monitoring")
    args = parser.parse_args(argv)
    try:
        decode_video(args.input, args.output)
    except Exception as error:
        message = str(error) or error.__class__.__name__
        if args.result_file is not None:
            _try_write_result(args.result_file, {"success": False, "error": message})
        print(f"frame-source: {message}", file=__import__("sys").stderr)
        return 1

    if args.result_file is not None:
        try:
            _write_result(args.result_file, {"success": True, "path": str(args.output)})
        except OSError as error:
            print(f"frame-source: could not write result file: {error}", file=__import__("sys").stderr)
            return 1
    print(f"normalized video to {args.output}")
    return 0


def _try_write_result(path: Path, payload: dict[str, Any]) -> None:
    try:
        _write_result(path, payload)
    except OSError:
        pass


def _write_result(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False
    ) as temporary:
        json.dump(payload, temporary, ensure_ascii=False, allow_nan=False)
        temporary.write("\n")
        temporary_path = Path(temporary.name)
    try:
        os.replace(temporary_path, path)
    except OSError:
        temporary_path.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
