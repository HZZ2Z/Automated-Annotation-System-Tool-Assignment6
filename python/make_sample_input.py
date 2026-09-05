"""Part 1.2 CLI for the deterministic synthetic annotation sample.

The no-argument invocation uses the canonical output and fixed seed required by
the reviewer workflow. Reusable rendering and defect planting remain in
:mod:`annotation_data.sample`; this adapter owns only arguments, exit codes, and
human-readable process output.
"""

import argparse
from pathlib import Path
import sys
from typing import Sequence

from annotation_data.sample import generate_sample


DEFAULT_OUTPUT = Path("sample/assignment_v1")
DEFAULT_SEED = 6006


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse optional output and seed overrides for deterministic generation.

    Defaults intentionally provide the canonical fixed-seed reviewer invocation;
    callers can pass ``argv`` to reuse the same contract in tests or automation.
    """
    parser = argparse.ArgumentParser(
        description="Generate the deterministic synthetic annotation sample."
    )
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
    """Generate the requested sample, returning ``0`` or a handled error ``1``.

    The supplied seed controls deterministic bytes. Existing output directories
    are refused rather than overwritten, preserving a previous reproducible run
    until a caller deliberately selects a new destination.
    """
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
