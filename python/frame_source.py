"""Part 1.3 command-line adapter for frame-accurate video normalization.

Argument parsing and process-facing progress/result files live here. Reusable
FFmpeg probing, decoding, validation, cancellation, cleanup, and atomic dataset
publication live in :mod:`annotation_data.frame_source` so tests and other
clients can call the same implementation without invoking a subprocess.
"""

import argparse
import json
import os
from pathlib import Path
import tempfile
from typing import Any, Sequence

from annotation_data.frame_source import VideoImportCancelled, decode_video


def main(argv: Sequence[str] | None = None) -> int:
    """Run one import request and return a process-compatible exit status.

    ``0`` means frames were published successfully, ``1`` represents a normal
    import or result-file error, and ``130`` records an explicit cancellation.
    The decoder remains the sole owner of frame output; this adapter only
    translates command-line state into its callback and cancellation contracts.
    """
    parser = argparse.ArgumentParser(description="Normalize a video into PNG frames and a manifest.")
    parser.add_argument("input", type=Path, help="video file to decode")
    parser.add_argument("--output", type=Path, required=True, help="new normalized output directory")
    parser.add_argument("--result-file", type=Path, help="JSON status file for process monitoring")
    parser.add_argument("--progress-file", type=Path, help="atomic JSON progress file")
    parser.add_argument("--cancel-file", type=Path, help="cancel when this file appears")
    parser.add_argument(
        "--staging-dir",
        type=Path,
        help="explicit new sibling staging directory used before atomic publication",
    )
    args = parser.parse_args(argv)
    last_progress: dict[str, Any] = {
        "version": 1,
        "state": "running",
        "stage": "probe",
        "completed": 0,
        "total": 1,
        "fraction": 0.0,
        "message": "Starting import",
    }

    def report_progress(payload: dict[str, Any]) -> None:
        nonlocal last_progress
        # Keep the most recent snapshot so terminal progress preserves context
        # even when decoding exits before another callback can be emitted.
        last_progress = payload.copy()
        if args.progress_file is not None:
            _write_result(args.progress_file, payload)

    def cancel_requested() -> bool:
        # File polling is intentionally side-effect free: an external UI can
        # request cancellation without sharing process memory with this CLI.
        return args.cancel_file is not None and args.cancel_file.exists()

    try:
        decode_video(
            args.input,
            args.output,
            progress_callback=report_progress if args.progress_file is not None else None,
            cancel_check=cancel_requested if args.cancel_file is not None else None,
            staging_dir=args.staging_dir,
        )
    except VideoImportCancelled as error:
        message = str(error) or "video import cancelled"
        if args.progress_file is not None:
            _try_write_result(
                args.progress_file,
                _terminal_progress(last_progress, "cancelled", "Import cancelled"),
            )
        if args.result_file is not None:
            _try_write_result(
                args.result_file,
                {"success": False, "cancelled": True, "error": message},
            )
        print(f"frame-source: {message}", file=__import__("sys").stderr)
        return 130
    except Exception as error:
        message = str(error) or error.__class__.__name__
        if args.progress_file is not None:
            _try_write_result(
                args.progress_file,
                _terminal_progress(last_progress, "failed", message),
            )
        if args.result_file is not None:
            _try_write_result(args.result_file, {"success": False, "error": message})
        print(f"frame-source: {message}", file=__import__("sys").stderr)
        return 1

    if args.result_file is not None:
        try:
            # Replace the status atomically so readers never observe partial JSON.
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


def _terminal_progress(
    previous: dict[str, Any], state: str, message: str
) -> dict[str, Any]:
    return {
        "version": 1,
        "state": state,
        "stage": str(previous.get("stage", "probe")),
        "completed": int(previous.get("completed", 0)),
        "total": max(1, int(previous.get("total", 1))),
        "fraction": min(1.0, max(0.0, float(previous.get("fraction", 0.0)))),
        "message": message,
    }


def _write_result(path: Path, payload: dict[str, Any]) -> None:
    """Atomically publish one JSON progress or result snapshot at ``path``."""
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
