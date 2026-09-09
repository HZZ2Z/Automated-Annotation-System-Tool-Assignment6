"""Prepare a 5-30 frame Endoscapes Poly acceptance workspace."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from annotation_data.endoscapes_fixture import BuildRequest, build_fixture


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--video-id", required=True, type=int)
    parser.add_argument("--start-frame", required=True, type=int)
    parser.add_argument("--end-frame", required=True, type=int)
    parser.add_argument("--key-frame", required=True, type=int)
    parser.add_argument("--instance-index", required=True, type=int)
    parser.add_argument("--copy", action="store_true", dest="copy_images",
                        help="copy images so the strict UI source plugin can open the fixture")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        result = build_fixture(BuildRequest(**vars(args)))
    except (OSError, ValueError) as error:
        print(f"Endoscapes fixture preparation failed: {error}")
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
