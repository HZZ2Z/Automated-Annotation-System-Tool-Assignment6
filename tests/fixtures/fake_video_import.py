"""Small process fixture for Godot's non-blocking import-controller tests."""

import argparse
import json
import os
from pathlib import Path
import tempfile
import time


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        json.dump(payload, handle)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--result-file", type=Path, required=True)
    parser.add_argument("--progress-file", type=Path, required=True)
    parser.add_argument("--cancel-file", type=Path, required=True)
    parser.add_argument("--staging-dir", type=Path, required=True)
    args = parser.parse_args()
    for completed in range(3):
        if args.cancel_file.exists():
            write_json(
                args.progress_file,
                {
                    "version": 1,
                    "state": "cancelled",
                    "stage": "extract",
                    "completed": completed,
                    "total": 3,
                    "fraction": completed / 3.0,
                    "message": "Import cancelled",
                },
            )
            write_json(
                args.result_file,
                {"success": False, "cancelled": True, "error": "video import cancelled"},
            )
            return 130
        write_json(
            args.progress_file,
            {
                "version": 1,
                "state": "running",
                "stage": "extract",
                "completed": completed,
                "total": 3,
                "fraction": completed / 3.0,
                "message": "fixture progress",
            },
        )
        time.sleep(0.08)
    args.staging_dir.mkdir()
    args.staging_dir.replace(args.output)
    write_json(
        args.progress_file,
        {
            "version": 1,
            "state": "completed",
            "stage": "publish",
            "completed": 1,
            "total": 1,
            "fraction": 1.0,
            "message": "Import complete",
        },
    )
    write_json(args.result_file, {"success": True, "path": str(args.output)})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
