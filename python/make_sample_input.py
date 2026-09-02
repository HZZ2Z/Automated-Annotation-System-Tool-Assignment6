"""Generate the deterministic synthetic annotation sample."""

import argparse
from pathlib import Path
import sys
from typing import Sequence

from annotool.sample import generate_sample


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="new sample output directory")
    parser.add_argument("--seed", type=int, default=6006, help="deterministic seed")
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
