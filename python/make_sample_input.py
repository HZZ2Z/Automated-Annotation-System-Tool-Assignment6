"""Generate the deterministic synthetic annotation sample."""

import argparse
from pathlib import Path
import sys
from typing import Sequence

from annotool.sample import generate_sample


DEFAULT_OUTPUT = Path("sample/assignment_v1")
DEFAULT_SEED = 6006


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"new sample output directory (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_SEED,
        help=f"deterministic seed (default: {DEFAULT_SEED})",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        generate_sample(args.output, seed=args.seed)
    except FileExistsError:
        print(f"error: output directory already exists: {args.output}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"Generated sample at {args.output}")
    print("Validation errors: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
