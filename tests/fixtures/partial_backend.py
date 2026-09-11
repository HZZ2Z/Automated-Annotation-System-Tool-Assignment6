"""Backend fixture that constructs successfully but lacks the worker contract."""
from __future__ import annotations


class PartialBackend:
    def __init__(self, job_dir):
        self.job_dir = job_dir

    def close(self):
        (self.job_dir / "closed.marker").write_text("closed\n", encoding="utf-8")


def create_backend(*, job_dir):
    return PartialBackend(job_dir)
