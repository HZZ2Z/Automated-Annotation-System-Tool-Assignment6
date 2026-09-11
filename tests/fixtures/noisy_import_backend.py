"""Backend fixture that deliberately logs while its module is imported."""
from __future__ import annotations

print("import-side-noise")


class NoisyImportBackend:
    def hello(self):
        return {"backend": "noisy-import"}

    def open_batch(self, frames, key_index, region):
        return {}

    def propagate(self, context):
        return {}

    def reanchor(self, frame_index, positive_points, negative_points, box, prompt_revision):
        return {}

    def close(self):
        pass


def create_backend():
    return NoisyImportBackend()
