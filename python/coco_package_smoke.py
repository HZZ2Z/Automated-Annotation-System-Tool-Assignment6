#!/usr/bin/env python3
"""Read every sample in a detached Project6 COCO training package."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from annotation_data.coco_package_loader import load_coco_package


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    args = parser.parse_args(argv)
    result = load_coco_package(args.package)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result.get("success") else 1


if __name__ == "__main__":
    raise SystemExit(main())
