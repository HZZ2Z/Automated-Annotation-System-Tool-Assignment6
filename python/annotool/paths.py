from pathlib import Path


def repository_root() -> Path:
    """Return the repository root derived from this installed source file."""
    return Path(__file__).resolve().parents[2]
