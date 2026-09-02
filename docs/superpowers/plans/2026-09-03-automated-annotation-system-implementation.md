# Automated Annotation System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Build the assignment-scoped Godot annotation client and Python support tools as one reliable load → edit → batch → verify → autosave → export → handoff workflow.

**Architecture:** JSON Schema and shared fixtures define the contract. Python owns deterministic data generation, video normalization, similarity calculation, validation, diffing, and package construction; Godot owns indexed playback, bounded frame loading, rendering, editing, review state, and the user workflow. Godot discovers four local plugin stages and invokes Python work asynchronously where file processing is required.

**Tech Stack:** Godot 4.7.2-stable with GDScript and Compatibility renderer; Python 3.10–3.14 (tested on 3.14.7); FFmpeg 6.1+; JSON Schema Draft 2020-12; NumPy; OpenCV headless; jsonschema; pytest; Mermaid.

**Spec:** docs/superpowers/specs/2026-09-03-automated-annotation-system-design.md

## Global Constraints

- Implement only the approved specification and the teacher's mandatory requirements.
- Do not add model inference/training, HTTP services, databases, cloud features, accounts, collaboration, Web/mobile clients, optical flow, polygon drawing, or polygon vertex editing.
- The original model-output files and in-memory model records are immutable.
- Image coordinates are top-left-origin pixel coordinates; frame indices are zero-based and contiguous.
- A region contains exactly one geometry: box or polygon.
- JSONL is the canonical corrected-annotation export.
- The only training delivery is a versioned file-based handoff package.
- All persistent annotation changes go through bounded command history with capacity 200.
- Long sources use a bounded cache and are never fully loaded into RAM.
- Python and Godot run the same valid/invalid contract fixtures.
- Tests are written before implementation for every behavior-bearing task.
- Generated samples, Godot imports, Python environments, build outputs, and credentials are not committed.

---

## Planned Repository Map

Each file has one primary responsibility.

~~~text
.
├── .gitignore
├── project.godot
├── pyproject.toml
├── requirements.lock
├── README.md
├── RESULTS.md
├── core/
│   ├── schemas/
│   │   ├── annotation-v1.schema.json
│   │   ├── dataset-manifest-v1.schema.json
│   │   ├── review-state-v1.schema.json
│   │   └── training-package-v1.schema.json
│   ├── fixtures/
│   │   ├── valid/
│   │   └── invalid/
│   └── taxonomy/classes.json
├── python/
│   ├── annotool/
│   │   ├── __init__.py
│   │   ├── contracts.py
│   │   ├── jsonl.py
│   │   ├── sample.py
│   │   ├── similarity.py
│   │   ├── frame_source.py
│   │   ├── diff.py
│   │   └── package.py
│   ├── make_sample_input.py
│   ├── frame_source.py
│   ├── validate_annotations.py
│   └── build_update_package.py
├── client/
│   ├── app/
│   │   ├── main.tscn
│   │   └── main.gd
│   ├── domain/
│   │   ├── annotation_validator.gd
│   │   ├── annotation_store.gd
│   │   ├── command.gd
│   │   ├── command_history.gd
│   │   └── commands/
│   ├── services/
│   │   ├── viewport_transform.gd
│   │   ├── frame_cache.gd
│   │   ├── propagation_service.gd
│   │   ├── verification_service.gd
│   │   ├── autosave_service.gd
│   │   └── process_service.gd
│   ├── pipeline/
│   │   ├── plugin_api.gd
│   │   └── plugin_registry.gd
│   ├── plugins/
│   │   ├── source/image_sequence_source/
│   │   ├── render/canvas_region_renderer/
│   │   ├── edit/basic_edit_tools/
│   │   └── feedback/file_training_handoff/
│   └── ui/
│       ├── annotation_viewport.gd
│       ├── annotation_viewport.tscn
│       ├── inspector_panel.gd
│       ├── inspector_panel.tscn
│       ├── timeline.gd
│       └── timeline.tscn
├── tests/
│   ├── python/
│   ├── godot/
│   │   ├── test_runner.gd
│   │   └── test_support.gd
│   ├── smoke/
│   │   └── edit_session.gd
│   └── expected/
└── docs/
    ├── architecture.md
    ├── plugin-api.md
    ├── model-team-interface.md
    └── reviewer-script.md
~~~

---

### Task 1: Reproducible project foundation

**Files:**
- Track unchanged: Project_6_Automated_Annotation_System_Assignment.md
- Create: .gitignore
- Create: pyproject.toml
- Create: python/annotool/__init__.py
- Create: project.godot
- Create: tests/python/test_environment.py
- Create: tests/godot/test_runner.gd
- Create: tests/godot/test_support.gd
- Create mechanically: requirements.lock

**Interfaces:**
- Consumes: Python 3.10–3.14, Godot 4.7.2-stable, FFmpeg 6.1+.
- Produces: the annotool Python package, pytest command, Godot headless test command, and pinned dependency lock used by every later task.

- [ ] **Step 1: Verify external executables**

Run:

~~~bash
python3 --version
godot --version
ffmpeg -version
git --version
~~~

Expected: Python reports 3.10–3.14, Godot reports 4.7.2.stable, FFmpeg reports 6.1 or newer, and Git is available. If Godot is absent, install the official 4.7.2-stable Linux build. If FFmpeg is absent, install the distribution FFmpeg package and re-run the checks before continuing.

- [ ] **Step 2: Write the failing Python environment test**

Create tests/python/test_environment.py:

~~~python
from pathlib import Path

import annotool


def test_repository_layout_is_importable() -> None:
    root = Path(__file__).resolve().parents[2]
    assert annotool.__version__ == "0.1.0"
    assert (root / "project.godot").is_file()
~~~

- [ ] **Step 3: Run the test and confirm the package is missing**

Run:

~~~bash
python3 -m pytest tests/python/test_environment.py -v
~~~

Expected: collection fails because annotool and/or pytest is not installed.

- [ ] **Step 4: Add the Python project metadata**

Create pyproject.toml with:

~~~toml
[build-system]
requires = ["setuptools>=75,<76"]
build-backend = "setuptools.build_meta"

[project]
name = "annotool"
version = "0.1.0"
requires-python = ">=3.10,<3.15"
dependencies = [
  "jsonschema>=4.26,<5",
  "numpy>=2.2,<3",
  "opencv-python-headless>=4.11,<5",
]

[project.optional-dependencies]
dev = ["pytest>=8.3,<9"]

[tool.setuptools]
package-dir = {"" = "python"}

[tool.pytest.ini_options]
pythonpath = ["python"]
testpaths = ["tests/python"]
~~~

Create python/annotool/__init__.py:

~~~python
"""Shared support code for the automated annotation tool."""

__version__ = "0.1.0"
~~~

- [ ] **Step 5: Add Godot and ignore configuration**

Create project.godot:

~~~ini
; Engine configuration file.
config_version=5

[application]
config/name="Automated Annotation System"
run/main_scene="res://client/app/main.tscn"

[display]
window/size/viewport_width=1280
window/size/viewport_height=800
window/size/window_width_override=1280
window/size/window_height_override=800

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
~~~

Create .gitignore:

~~~gitignore
.venv/
__pycache__/
*.py[cod]
.pytest_cache/
.godot/
.tools/
sample/
build/
dist/
exports/
autosave/
*.tmp
*.log
~~~

Create tests/godot/test_support.gd:

~~~gdscript
class_name TestSupport
extends RefCounted

var failures: Array[String] = []

func expect_true(value: bool, message: String) -> void:
    if not value:
        failures.append(message)
~~~

Create tests/godot/test_runner.gd:

~~~gdscript
extends SceneTree

func _initialize() -> void:
    print("No Godot tests registered yet.")
    quit(0)
~~~

- [ ] **Step 6: Install and lock Python dependencies**

Run:

~~~bash
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -e '.[dev]'
.venv/bin/python -m pip freeze --exclude-editable > requirements.lock
~~~

Expected: requirements.lock contains exact installed versions of jsonschema, NumPy, OpenCV headless, pytest, and their transitive dependencies.

- [ ] **Step 7: Run both baseline test commands**

Run:

~~~bash
.venv/bin/python -m pytest tests/python/test_environment.py -v
godot --headless --path . --script tests/godot/test_runner.gd
~~~

Expected: pytest passes; Godot prints the no-tests message and exits 0.

- [ ] **Step 8: Commit**

~~~bash
git add Project_6_Automated_Annotation_System_Assignment.md .gitignore project.godot pyproject.toml requirements.lock python/annotool/__init__.py tests/python/test_environment.py tests/godot
git commit -m "chore: establish reproducible project foundation"
~~~

---

### Task 2: Canonical schemas and Python validation

**Files:**
- Create: core/schemas/annotation-v1.schema.json
- Create: core/schemas/dataset-manifest-v1.schema.json
- Create: core/schemas/review-state-v1.schema.json
- Create: core/taxonomy/classes.json
- Create: core/fixtures/valid/annotation-box.json
- Create: core/fixtures/valid/annotation-polygon.json
- Create: core/fixtures/valid/dataset-manifest.json
- Create: core/fixtures/invalid/annotation-negative-width.json
- Create: core/fixtures/invalid/annotation-both-geometries.json
- Create: core/fixtures/invalid/annotation-bad-confidence.json
- Create: core/fixtures/invalid/manifest-frame-gap.json
- Create: python/annotool/contracts.py
- Create: python/annotool/jsonl.py
- Create: python/validate_annotations.py
- Test: tests/python/test_contracts.py

**Interfaces:**
- Consumes: repository root and JSON Schema Draft 2020-12.
- Produces: load_schema(name: str) -> dict, validate_instance(data: dict, schema_name: str) -> list[str], validate_annotation_semantics(record: dict) -> list[str], read_jsonl(path: Path) -> list[dict], and write_jsonl_atomic(path: Path, records: list[dict]) -> None.

- [ ] **Step 1: Write failing contract tests**

Create tests/python/test_contracts.py:

~~~python
import json
from pathlib import Path

from annotool.contracts import validate_instance


FIXTURES = Path("core/fixtures")


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_valid_box_annotation_passes() -> None:
    errors = validate_instance(
        load(FIXTURES / "valid/annotation-box.json"),
        "annotation-v1.schema.json",
    )
    assert errors == []


def test_negative_box_width_is_rejected() -> None:
    errors = validate_instance(
        load(FIXTURES / "invalid/annotation-negative-width.json"),
        "annotation-v1.schema.json",
    )
    assert any("exclusiveMinimum" in error or "greater than 0" in error for error in errors)


def test_region_cannot_have_box_and_polygon() -> None:
    errors = validate_instance(
        load(FIXTURES / "invalid/annotation-both-geometries.json"),
        "annotation-v1.schema.json",
    )
    assert errors
~~~

- [ ] **Step 2: Run the focused tests**

Run:

~~~bash
.venv/bin/python -m pytest tests/python/test_contracts.py -v
~~~

Expected: import fails because annotool.contracts does not exist.

- [ ] **Step 3: Create the annotation schema and fixtures**

The annotation schema must declare Draft 2020-12, reject unknown top-level and region fields, require schema_version = 1, dataset_id, source, frame >= 0, image_size with two positive integers, and regions. Define box as four numbers with width and height strictly positive. Define polygon as at least three two-number vertices. Use oneOf so exactly one of box and polygon is present. Constrain confidence to 0–1 and allow track_id to be string or null.

Create core/fixtures/valid/annotation-box.json with this exact minimal record:

~~~json
{
  "schema_version": 1,
  "dataset_id": "fixture-v1",
  "source": "model_output_v1",
  "frame": 0,
  "time_s": 0.0,
  "image_size": [640, 360],
  "regions": [
    {
      "id": "fixture-r1",
      "class": "grasper",
      "kind": "instrument",
      "box": [10, 20, 40, 30],
      "conf": 0.9,
      "track_id": "T01",
      "filled": false
    }
  ]
}
~~~

Create the polygon fixture with one polygon and no box. Derive the three invalid annotation fixtures by changing width to -1, adding a polygon alongside a box, and changing confidence to 1.5.

- [ ] **Step 4: Create manifest, review-state, and taxonomy contracts**

The manifest schema requires zero-based contiguous frame entries semantically, positive dimensions, positive frame_count, positive nominal_fps, model_version, and taxonomy_version. JSON Schema checks shapes; validate_manifest_semantics checks index continuity, count, unique frame paths, and monotonically non-decreasing timestamps.

The review-state schema requires dataset_id, frames keyed by frame index with verified boolean, and batch markers containing keyframe, start_frame, end_frame, mode enum merge/overwrite, and threshold.

Create core/taxonomy/classes.json:

~~~json
{
  "taxonomy_version": "sample-taxonomy-v1",
  "kinds": ["instrument", "anatomy", "region"],
  "classes": [
    {"id": "grasper", "kind": "instrument", "color": "#ef4444"},
    {"id": "scissors", "kind": "instrument", "color": "#f59e0b"},
    {"id": "cystic_duct", "kind": "anatomy", "color": "#22c55e"},
    {"id": "gallbladder", "kind": "anatomy", "color": "#3b82f6"},
    {"id": "unknown", "kind": "region", "color": "#a855f7"}
  ]
}
~~~

- [ ] **Step 5: Implement the validator**

Create python/annotool/contracts.py around these signatures:

~~~python
from functools import lru_cache
import json
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = ROOT / "core/schemas"


@lru_cache(maxsize=None)
def load_schema(name: str) -> dict[str, Any]:
    return json.loads((SCHEMA_DIR / name).read_text(encoding="utf-8"))


def validate_instance(data: dict[str, Any], schema_name: str) -> list[str]:
    validator = Draft202012Validator(load_schema(schema_name))
    errors = sorted(validator.iter_errors(data), key=lambda item: list(item.path))
    return [
        f"{'.'.join(str(part) for part in error.absolute_path) or '$'}: {error.message}"
        for error in errors
    ]
~~~

Add validate_manifest_semantics(record) and validate_annotation_semantics(record). The annotation semantic validator rejects duplicate region IDs within one frame, boxes outside image bounds, and polygon vertices outside image bounds. The manifest semantic validator applies the exact continuity rules above. The CLI accepts one JSON object or JSONL records based on file suffix, prints one error per line, and exits 0 only when every record passes.

- [ ] **Step 6: Implement atomic JSONL helpers**

Create python/annotool/jsonl.py with:

~~~python
import json
import os
from pathlib import Path
from typing import Iterable


def read_jsonl(path: Path) -> list[dict]:
    records: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if line.strip():
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError as error:
                    raise ValueError(f"{path}:{line_number}: {error.msg}") from error
    return records


def write_jsonl_atomic(path: Path, records: Iterable[dict]) -> None:
    temp_path = path.with_suffix(path.suffix + ".tmp")
    with temp_path.open("w", encoding="utf-8", newline="\n") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    temp_path.replace(path)
~~~

- [ ] **Step 7: Run all contract tests**

Run:

~~~bash
.venv/bin/python -m pytest tests/python/test_contracts.py -v
.venv/bin/python python/validate_annotations.py core/fixtures/valid/annotation-box.json
~~~

Expected: tests pass and CLI exits 0 for the valid fixture. Run the CLI against a negative-width fixture and confirm it exits nonzero with a field path.

- [ ] **Step 8: Commit**

~~~bash
git add core python/annotool/contracts.py python/annotool/jsonl.py python/validate_annotations.py tests/python/test_contracts.py
git commit -m "feat: define and validate annotation contracts"
~~~

---

### Task 3: Deterministic synthetic sample

**Files:**
- Create: python/annotool/sample.py
- Create: python/make_sample_input.py
- Create: tests/python/test_sample.py
- Create: tests/expected/sample-defects.json

**Interfaces:**
- Consumes: annotation and dataset manifest contracts from Task 2.
- Produces: generate_sample(output_dir: Path, seed: int = 6006) -> dict[str, str] and a CLI that writes frames, model_output.jsonl, manifest.json, expected_defects.json, and hashes.json.

- [ ] **Step 1: Write failing deterministic-sample tests**

Create tests/python/test_sample.py:

~~~python
import json
from pathlib import Path

from annotool.sample import generate_sample


def test_sample_is_deterministic(tmp_path: Path) -> None:
    first = generate_sample(tmp_path / "first", seed=6006)
    second = generate_sample(tmp_path / "second", seed=6006)
    assert first == second


def test_sample_contains_required_defects(tmp_path: Path) -> None:
    generate_sample(tmp_path / "sample", seed=6006)
    defects = json.loads((tmp_path / "sample/expected_defects.json").read_text())
    assert set(defects["types"]) == {
        "drift",
        "wrong_class",
        "missed_region",
        "hallucinated_region",
        "track_id_swap",
    }
    assert defects["similar_run"] == [40, 59]
~~~

- [ ] **Step 2: Run tests and confirm failure**

Run:

~~~bash
.venv/bin/python -m pytest tests/python/test_sample.py -v
~~~

Expected: import fails because annotool.sample does not exist.

- [ ] **Step 3: Implement clean frame and ground-truth generation**

Implement 120 640×360 BGR frames at 30 FPS from NumPy arrays. Create colored rectangles and polygons with deterministic positions derived only from frame index and seed. Use 20 regions in the benchmark/sample view, with instrument, anatomy, and region kinds. Frames 40–59 use a constant background plus sub-threshold deterministic one-level intensity variation.

The function starts with:

~~~python
FRAME_COUNT = 120
WIDTH = 640
HEIGHT = 360
FPS = 30.0
SIMILAR_START = 40
SIMILAR_END = 59


def generate_sample(output_dir: Path, seed: int = 6006) -> dict[str, str]:
    rng = np.random.default_rng(seed)
    output_dir.mkdir(parents=True, exist_ok=False)
    frames_dir = output_dir / "frames"
    frames_dir.mkdir()
~~~

Every frame file is named frame_000000.png through frame_000119.png.

- [ ] **Step 4: Plant model-output defects without changing ground truth**

Create model output as a deep copy of ground truth, then apply:

- geometry drift to regions sample-r03 and sample-r04 on frames 12 and 13
- wrong class on sample-r05 at frame 24
- remove sample-r07 at frame 36
- add hallucinated region hallucinated-f072 at frame 72
- swap track IDs of sample-r01 and sample-r02 at frame 90

Write these exact locations and region IDs to expected_defects.json. Do not commit a separate ground-truth annotation export; the expected-defects manifest is the test oracle.

- [ ] **Step 5: Validate and hash all generated outputs**

Validate manifest.json and every model_output.jsonl record before returning. Hash frame content, manifest, annotations, and defects using SHA-256. Return a mapping from relative path to digest so tests can compare two output directories without comparing paths.

- [ ] **Step 6: Add the required CLI wrapper**

Create python/make_sample_input.py with argparse options --output and --seed. It calls generate_sample and prints the output path and zero validation errors. A second run into an existing directory must exit nonzero with a concise message rather than overwrite files.

- [ ] **Step 7: Run focused and full Python tests**

Run:

~~~bash
.venv/bin/python -m pytest tests/python/test_sample.py -v
.venv/bin/python python/make_sample_input.py --output /tmp/annotool-sample --seed 6006
.venv/bin/python python/validate_annotations.py /tmp/annotool-sample/model_output.jsonl
~~~

Expected: tests pass, 120 frames exist, and validation reports zero errors.

- [ ] **Step 8: Commit**

~~~bash
git add python/annotool/sample.py python/make_sample_input.py tests/python/test_sample.py tests/expected/sample-defects.json
git commit -m "feat: generate deterministic annotated sample"
~~~

---

### Task 4: Video normalization and similarity

**Files:**
- Create: python/annotool/similarity.py
- Create: python/annotool/frame_source.py
- Create: python/frame_source.py
- Test: tests/python/test_similarity.py
- Test: tests/python/test_frame_source.py

**Interfaces:**
- Consumes: FFmpeg, OpenCV, manifest validator.
- Produces: normalized_mad(left: ndarray, right: ndarray) -> float, contiguous_run(scores: list[float], keyframe: int, threshold: float) -> tuple[int, int], and decode_video(input_path: Path, output_dir: Path) -> dict.

- [ ] **Step 1: Write failing similarity tests**

Create tests/python/test_similarity.py:

~~~python
import numpy as np

from annotool.similarity import contiguous_run, normalized_mad


def test_identical_frames_have_zero_distance() -> None:
    frame = np.full((32, 32, 3), 64, dtype=np.uint8)
    assert normalized_mad(frame, frame) == 0.0


def test_contiguous_run_stops_at_threshold_boundaries() -> None:
    scores = [0.4, 0.01, 0.01, 0.03, 0.01]
    assert contiguous_run(scores, keyframe=2, threshold=0.02) == (1, 3)
~~~

The scores list uses scores[i] for the transition from frame i to frame i + 1, so a keyframe at 2 expands left through scores[1] and right through scores[2].

- [ ] **Step 2: Implement similarity**

Create python/annotool/similarity.py:

~~~python
import cv2
import numpy as np


def normalized_mad(left: np.ndarray, right: np.ndarray) -> float:
    left_small = cv2.resize(left, (64, 64), interpolation=cv2.INTER_AREA)
    right_small = cv2.resize(right, (64, 64), interpolation=cv2.INTER_AREA)
    left_gray = cv2.cvtColor(left_small, cv2.COLOR_BGR2GRAY).astype(np.float32)
    right_gray = cv2.cvtColor(right_small, cv2.COLOR_BGR2GRAY).astype(np.float32)
    return float(np.mean(np.abs(left_gray - right_gray)) / 255.0)


def contiguous_run(
    scores: list[float],
    keyframe: int,
    threshold: float = 0.02,
) -> tuple[int, int]:
    start = keyframe
    end = keyframe
    while start > 0 and scores[start - 1] < threshold:
        start -= 1
    while end < len(scores) and scores[end] < threshold:
        end += 1
    return start, end
~~~

- [ ] **Step 3: Write a failing frame-source integration test**

Generate a three-frame lossless test video with FFmpeg from temporary PNGs, call decode_video, and assert frame entries are [0, 1, 2], paths exist, timestamps are monotonic, and similarity_scores has length 2. Mark the test skipped only when shutil.which("ffmpeg") is None.

- [ ] **Step 4: Implement video decoding**

Use subprocess.run with an argument list, never shell=True. Probe width, height, nominal frame rate, and per-frame timestamps with ffprobe JSON. Extract lossless PNG frames with:

~~~python
command = [
    "ffmpeg",
    "-hide_banner",
    "-loglevel",
    "error",
    "-i",
    str(input_path),
    "-vsync",
    "0",
    str(frames_dir / "frame_%06d.png"),
]
~~~

Rename or account for FFmpeg's one-based filenames so the manifest remains zero-based. Reject output if indices are not contiguous or if probed timestamp count does not match extracted frame count. Compute adjacent similarity scores and write them into manifest.json.

- [ ] **Step 5: Add the required CLI**

Create python/frame_source.py with input path, --output, and optional --result-file arguments. It exits nonzero for missing files, FFmpeg failure, invalid video, or output collision and prints concise errors without Python tracebacks. When --result-file is supplied, atomically write {"success": true, "path": "<normalized directory>"} or {"success": false, "error": "<message>"} so Godot can monitor the process without capturing stdout.

- [ ] **Step 6: Verify sample similarity boundaries**

Add a test that reads generated sample frames, computes scores, calls contiguous_run at keyframe 50 with threshold 0.02, and asserts (40, 59). Assert transitions 39→40 and 59→60 are at or above the threshold.

- [ ] **Step 7: Run the frame-source suite**

Run:

~~~bash
.venv/bin/python -m pytest tests/python/test_similarity.py tests/python/test_frame_source.py -v
~~~

Expected: all tests pass.

- [ ] **Step 8: Commit**

~~~bash
git add python/annotool/similarity.py python/annotool/frame_source.py python/frame_source.py tests/python/test_similarity.py tests/python/test_frame_source.py
git commit -m "feat: normalize videos and measure frame similarity"
~~~

---

### Task 5: Godot contract validation and immutable annotation store

**Files:**
- Create: client/domain/annotation_validator.gd
- Create: client/domain/annotation_store.gd
- Create: client/domain/command.gd
- Create: client/domain/command_history.gd
- Create: tests/godot/test_annotation_validator.gd
- Create: tests/godot/test_annotation_store.gd
- Modify: tests/godot/test_runner.gd

**Interfaces:**
- Consumes: JSON fixtures and schema semantics from Task 2.
- Produces: AnnotationValidator.validate_record(record: Dictionary) -> PackedStringArray; AnnotationStore.load_model_records(records: Array[Dictionary]) -> PackedStringArray; get_model_record(frame: int) -> Dictionary; get_corrected_record(frame: int) -> Dictionary; replace_corrected_record(frame: int, record: Dictionary) -> PackedStringArray; snapshot_corrected() -> Array[Dictionary]; Command.apply(store: AnnotationStore) -> PackedStringArray; Command.revert(store: AnnotationStore) -> void; CommandHistory.execute(command, store) -> PackedStringArray; undo(store) and redo(store).

- [ ] **Step 1: Register failing Godot tests**

Update tests/godot/test_runner.gd to instantiate a shared TestSupport, execute static run(support) functions from the registered test scripts, print every failure, and exit 1 when failures is non-empty.

Create tests/godot/test_annotation_validator.gd:

~~~gdscript
extends RefCounted

static func run(support: TestSupport) -> void:
    var validator := AnnotationValidator.new()
    var valid := _read_json("res://core/fixtures/valid/annotation-box.json")
    var invalid := _read_json("res://core/fixtures/invalid/annotation-negative-width.json")
    support.expect_true(validator.validate_record(valid).is_empty(), "valid box fixture rejected")
    support.expect_true(not validator.validate_record(invalid).is_empty(), "negative width accepted")

static func _read_json(path: String) -> Dictionary:
    return JSON.parse_string(FileAccess.get_file_as_string(path))
~~~

- [ ] **Step 2: Run the tests and confirm missing classes**

Run:

~~~bash
godot --headless --path . --script tests/godot/test_runner.gd
~~~

Expected: parse or identifier errors for AnnotationValidator and AnnotationStore.

- [ ] **Step 3: Implement equivalent client validation**

Create client/domain/annotation_validator.gd:

~~~gdscript
class_name AnnotationValidator
extends RefCounted

func validate_record(record: Dictionary) -> PackedStringArray:
    var errors := PackedStringArray()
    for field in ["schema_version", "dataset_id", "source", "frame", "image_size", "regions"]:
        if not record.has(field):
            errors.append("%s: required field missing" % field)
    if not errors.is_empty():
        return errors
    if record.schema_version != 1:
        errors.append("schema_version: expected 1")
    if not record.frame is int or record.frame < 0:
        errors.append("frame: expected non-negative integer")
    if not record.image_size is Array or record.image_size.size() != 2:
        errors.append("image_size: expected [width, height]")
        return errors
    var ids := {}
    for index in record.regions.size():
        _validate_region(record.regions[index], index, record.image_size, ids, errors)
    return errors
~~~

Implement _validate_region so it applies the same required fields, exactly-one-geometry, confidence, unique ID, positive box size, bounds, polygon cardinality, and vertex bounds rules as Python. Read every fixture in core/fixtures/valid and core/fixtures/invalid in the test and assert parity by directory.

- [ ] **Step 4: Write failing immutable-store tests**

Create tests/godot/test_annotation_store.gd. Load two valid records, mutate the Dictionary returned by get_model_record, and assert a later get_model_record call remains unchanged. Replace a corrected record and assert the model record still matches its original JSON string. Also assert a schema-invalid replacement is rejected and does not mutate corrected state.

- [ ] **Step 5: Implement AnnotationStore**

Create client/domain/annotation_store.gd:

~~~gdscript
class_name AnnotationStore
extends RefCounted

var _model_records: Dictionary = {}
var _corrected_records: Dictionary = {}
var _dirty_frames: Dictionary = {}
var _validator := AnnotationValidator.new()

func load_model_records(records: Array[Dictionary]) -> PackedStringArray:
    var errors := PackedStringArray()
    var next_model := {}
    for record in records:
        var record_errors := _validator.validate_record(record)
        if not record_errors.is_empty():
            errors.append_array(record_errors)
        else:
            next_model[record.frame] = record.duplicate(true)
    if not errors.is_empty():
        return errors
    _model_records = next_model
    _corrected_records = next_model.duplicate(true)
    _dirty_frames.clear()
    return errors

func get_model_record(frame: int) -> Dictionary:
    return _model_records.get(frame, {}).duplicate(true)

func get_corrected_record(frame: int) -> Dictionary:
    return _corrected_records.get(frame, {}).duplicate(true)

func replace_corrected_record(frame: int, record: Dictionary) -> PackedStringArray:
    var errors := _validator.validate_record(record)
    if errors.is_empty() and _corrected_records.has(frame):
        _corrected_records[frame] = record.duplicate(true)
        _dirty_frames[frame] = true
    return errors
~~~

Add get_frame_count, get_dirty_frames, clear_dirty, snapshot_corrected, and model_digest. Return deep copies from every public read.

snapshot_corrected returns all frames in index order and sets source to human_corrected in the returned copies. It never changes model records. Add a test asserting all exported snapshot sources are human_corrected while model sources remain model_output_v1.

- [ ] **Step 6: Implement the command base and bounded history**

Create client/domain/command.gd:

~~~gdscript
class_name EditCommand
extends RefCounted

func apply(_store: AnnotationStore) -> PackedStringArray:
    return PackedStringArray(["command apply not implemented"])

func revert(_store: AnnotationStore) -> void:
    pass
~~~

Create CommandHistory with capacity default 200. execute applies a command and only pushes it when no errors are returned. undo reverts the last command and moves it to redo. redo applies the last redo command. A successful new command clears redo; exceeding capacity drops the oldest undo entry.

- [ ] **Step 7: Run Godot contract/store tests**

Run:

~~~bash
godot --headless --path . --script tests/godot/test_runner.gd
~~~

Expected: fixture parity, immutability, invalid replacement, and 200-command capacity tests pass.

- [ ] **Step 8: Commit**

~~~bash
git add client/domain tests/godot
git commit -m "feat: validate and store immutable annotation records"
~~~

---

### Task 6: Plugin registry, source plugin, and bounded frame cache

**Files:**
- Create: client/pipeline/plugin_api.gd
- Create: client/pipeline/plugin_registry.gd
- Create: client/services/frame_cache.gd
- Create: client/plugins/source/image_sequence_source/plugin.json
- Create: client/plugins/source/image_sequence_source/plugin.gd
- Create: tests/godot/fixtures/plugins/valid/plugin.json
- Create: tests/godot/fixtures/plugins/valid/plugin.gd
- Create: tests/godot/fixtures/plugins/bad_api/plugin.json
- Create: tests/godot/test_plugin_registry.gd
- Create: tests/godot/test_source_plugin.gd
- Modify: tests/godot/test_runner.gd

**Interfaces:**
- Consumes: normalized manifest and model-output JSONL.
- Produces: PluginApi constants; PluginRegistry.discover(root: String) -> PackedStringArray; get_plugin(stage: String, id: String) -> RefCounted; FrameCache.get_value(index: int, loader: Callable) -> Variant; source plugin open(path: String) -> PackedStringArray, get_frame_count() -> int, get_frame_entry(index: int) -> Dictionary, get_model_records() -> Array[Dictionary], load_texture(index: int) -> Texture2D, and close().

- [ ] **Step 1: Write failing registry tests**

Create tests/godot/test_plugin_registry.gd:

~~~gdscript
extends RefCounted

static func run(support: TestSupport) -> void:
    var registry := PluginRegistry.new()
    var errors := registry.discover("res://tests/godot/fixtures/plugins")
    support.expect_true(registry.get_plugin("source", "fixture-source") != null, "valid plugin not loaded")
    support.expect_true(errors.any(func(item: String) -> bool: return "api_version" in item), "bad API not reported")
~~~

Fixtures use api_version 1 for valid and 99 for invalid.

- [ ] **Step 2: Implement API constants and registry**

Create client/pipeline/plugin_api.gd:

~~~gdscript
class_name PluginApi
extends RefCounted

const API_VERSION := 1
const STAGES := ["source", "render", "edit", "feedback"]
~~~

PluginRegistry scans immediate child directories, reads plugin.json, validates id/version/api_version/stage/entry, rejects duplicate IDs per stage, loads the entry script, instantiates it, and verifies the instance exposes the documented methods for its stage before storing it by stage and ID. One broken plugin appends a readable error and does not stop discovery of other plugins.

- [ ] **Step 3: Write failing cache tests**

In tests/godot/test_source_plugin.gd, create a FrameCache with max_size 3, load frames 0, 1, 2, touch 0, load 3, and assert frame 1 was evicted while 0, 2, 3 remain. Assert max_size never exceeds 3.

- [ ] **Step 4: Implement the LRU cache**

Create client/services/frame_cache.gd:

~~~gdscript
class_name FrameCache
extends RefCounted

var max_size := 12
var _values: Dictionary = {}
var _order: Array[int] = []

func _init(size: int = 12) -> void:
    max_size = maxi(1, size)

func get_value(index: int, loader: Callable) -> Variant:
    if _values.has(index):
        _touch(index)
        return _values[index]
    var value: Variant = loader.call(index)
    if value == null:
        return null
    _values[index] = value
    _touch(index)
    while _order.size() > max_size:
        _values.erase(_order.pop_front())
    return value
~~~

Add has(index), size(), clear(), and _touch(index).

- [ ] **Step 5: Implement the normalized image-sequence source plugin**

The plugin opens only a directory containing manifest.json, frames, and model_output.jsonl. It validates paths are relative and remain under the source root. It parses manifest and JSONL, checks frame counts and indices, and only then replaces its current state. load_texture uses Image.load followed by ImageTexture.create_from_image and the cache.

Create plugin.json:

~~~json
{
  "id": "image_sequence_source",
  "version": "1.0.0",
  "api_version": 1,
  "stage": "source",
  "entry": "plugin.gd"
}
~~~

The plugin script exposes the exact source signatures in this task. Existing valid state remains intact when a replacement open fails.

- [ ] **Step 6: Test real sample loading and recoverable errors**

Generate a sample under /tmp, pass the path to the source plugin in a headless test, and assert 120 frames, frame 0 texture dimensions 640×360, and 120 model records. Then attempt to open a missing directory and assert errors are returned while the original sample remains open. Also test out-of-range texture requests return null plus a readable last_error.

- [ ] **Step 7: Run registry/source tests**

Run:

~~~bash
godot --headless --path . --script tests/godot/test_runner.gd
~~~

Expected: registry isolation, cache bound, sample loading, and replacement-failure tests pass.

- [ ] **Step 8: Commit**

~~~bash
git add client/pipeline client/services/frame_cache.gd client/plugins/source tests/godot
git commit -m "feat: load frame sources through plugin registry"
~~~

---

### Task 7: Viewport transform and region renderer

**Files:**
- Create: client/services/viewport_transform.gd
- Create: client/plugins/render/canvas_region_renderer/plugin.json
- Create: client/plugins/render/canvas_region_renderer/plugin.gd
- Create: client/ui/annotation_viewport.gd
- Create: client/ui/annotation_viewport.tscn
- Create: tests/godot/test_viewport_transform.gd
- Create: tests/godot/test_renderer.gd
- Modify: tests/godot/test_runner.gd

**Interfaces:**
- Consumes: Texture2D, annotation record, taxonomy colors.
- Produces: ViewportTransform.configure(image_size: Vector2, viewport_rect: Rect2); image_to_viewport(point: Vector2) -> Vector2; viewport_to_image(point: Vector2) -> Vector2; zoom_at(viewport_point: Vector2, factor: float); pan_by(delta: Vector2); render plugin set_state(texture, record, transform, selected_id, opacity), draw(canvas: CanvasItem), and hit_test(image_point: Vector2) -> Dictionary.

- [ ] **Step 1: Write failing round-trip and letterbox tests**

Create tests/godot/test_viewport_transform.gd:

~~~gdscript
extends RefCounted

static func run(support: TestSupport) -> void:
    var transform := ViewportTransform.new()
    transform.configure(Vector2(640, 360), Rect2(0, 0, 1000, 800))
    var image_point := Vector2(320, 180)
    var viewport_point := transform.image_to_viewport(image_point)
    support.expect_true(viewport_point.distance_to(Vector2(500, 400)) < 0.001, "center mapping wrong")
    var round_trip := transform.viewport_to_image(viewport_point)
    support.expect_true(round_trip.distance_to(image_point) < 0.001, "inverse mapping wrong")
~~~

Add tests that zoom_at keeps the image point under the cursor fixed and pan_by changes both drawing and inverse mapping consistently.

- [ ] **Step 2: Implement ViewportTransform**

Store image_size, viewport_rect, fit_scale, user_zoom clamped to 0.1–20.0, pan, and letterbox offset. configure recomputes fit scale as min(viewport width/image width, viewport height/image height). image_to_viewport and viewport_to_image are exact inverses.

- [ ] **Step 3: Write failing geometry hit tests**

Create tests/godot/test_renderer.gd with one box and one concave polygon. Assert points inside hit their region, points outside return an empty Dictionary, and reverse region order makes the visually topmost region win. Use image coordinates so tests remain independent of zoom.

- [ ] **Step 4: Implement the render plugin**

Create plugin.json with id canvas_region_renderer, version 1.0.0, api_version 1, stage render, entry plugin.gd.

The plugin:

- stores state but never owns annotation data
- draws the image fitted through ViewportTransform
- draws box outlines and optional fills
- draws closed polygon outlines and fills
- draws class color, label, optional confidence, selected emphasis, and box resize handles
- performs box containment and point-in-polygon hit testing in image coordinates
- iterates hit candidates in reverse draw order

Use one canvas and cached Color/taxonomy lookups. Do not instantiate one node per region.

- [ ] **Step 5: Implement AnnotationViewport interaction shell**

The custom Control owns ViewportTransform, delegates drawing/hit testing to the render plugin, queues redraw only when texture, record, selection, opacity, or transform changes, supports wheel zoom around cursor, and supports middle-button or Space+left-button pan. It emits:

~~~gdscript
signal region_selected(region_id: String)
signal image_pointer_event(event: InputEvent, image_position: Vector2)
signal transform_changed
~~~

Do not mutate annotations in this task.

- [ ] **Step 6: Add transformed selection test**

Configure zoom and pan, map a known image point to viewport coordinates, feed that point into AnnotationViewport selection, and assert the correct region ID is emitted. This catches renderer/input transform divergence.

- [ ] **Step 7: Run rendering tests**

Run:

~~~bash
godot --headless --path . --script tests/godot/test_runner.gd
~~~

Expected: all coordinate, zoom-anchor, letterbox, box, polygon, and transformed hit tests pass.

- [ ] **Step 8: Commit**

~~~bash
git add client/services/viewport_transform.gd client/plugins/render client/ui/annotation_viewport.gd client/ui/annotation_viewport.tscn tests/godot
git commit -m "feat: render and pick transformed regions"
~~~

---

### Task 8: Annotation commands and basic edit-tools plugin

**Files:**
- Create: client/domain/commands/replace_frame_command.gd
- Create: client/domain/commands/move_region_command.gd
- Create: client/domain/commands/resize_box_command.gd
- Create: client/domain/commands/add_box_command.gd
- Create: client/domain/commands/delete_region_command.gd
- Create: client/domain/commands/relabel_region_command.gd
- Create: client/domain/commands/set_track_id_command.gd
- Create: client/domain/commands/toggle_fill_command.gd
- Create: client/plugins/edit/basic_edit_tools/plugin.json
- Create: client/plugins/edit/basic_edit_tools/plugin.gd
- Create: client/ui/inspector_panel.gd
- Create: client/ui/inspector_panel.tscn
- Create: tests/godot/test_edit_commands.gd
- Create: tests/godot/test_keyboard_editing.gd
- Modify: tests/godot/test_runner.gd

**Interfaces:**
- Consumes: AnnotationStore, CommandHistory, selected frame/region, image pointer events.
- Produces: commands whose constructors capture frame, region ID, and requested change; edit plugin activate(context: Dictionary), handle_pointer(event, image_position) -> void, handle_key(event) -> bool, begin_add_box(), and cancel(); inspector emits relabel_requested, delete_requested, fill_requested, and geometry_requested.

- [ ] **Step 1: Write failing command tests**

Create table-driven tests that run move, resize, add, delete, relabel, track-ID change, and fill commands. For every command:

1. snapshot corrected record
2. apply through CommandHistory
3. assert expected change
4. undo and assert exact snapshot equality
5. redo and assert expected change
6. assert model record remains equal to its original snapshot

Also assert resize to zero width and move outside image bounds return validation errors and are not added to history.

- [ ] **Step 2: Implement ReplaceFrameCommand**

This base concrete command captures deep copies of before and after records:

~~~gdscript
class_name ReplaceFrameCommand
extends EditCommand

var frame: int
var before: Dictionary
var after: Dictionary

func _init(frame_index: int, old_record: Dictionary, new_record: Dictionary) -> void:
    frame = frame_index
    before = old_record.duplicate(true)
    after = new_record.duplicate(true)

func apply(store: AnnotationStore) -> PackedStringArray:
    return store.replace_corrected_record(frame, after)

func revert(store: AnnotationStore) -> void:
    store.replace_corrected_record(frame, before)
~~~

- [ ] **Step 3: Implement focused edit-command constructors**

Each focused command derives or delegates to ReplaceFrameCommand, locates the region by ID, creates a deep-copy after record, applies exactly one change, and lets AnnotationStore validation decide acceptance. AddBoxCommand creates an ID unique within the current frame using frame index and a monotonically increasing local counter; it never reuses a deleted ID during the session. SetTrackIdCommand accepts a non-empty string or null and is the only edit path that mutates track_id.

- [ ] **Step 4: Write failing pointer and keyboard behavior tests**

Cover:

- click selection
- drag commits one move command on release
- resize-handle drag commits one resize command
- add-box pointer drag
- Tab and Shift+Tab region cycling
- Arrow, Shift+Arrow, and Ctrl+Shift+Arrow movement by 1, 5, and 10 pixels
- Alt variants resize by 1, 5, and 10 pixels
- Delete removes selection
- Ctrl+Z and Ctrl+Shift+Z
- keyboard-only add-box workflow and Enter confirmation

- [ ] **Step 5: Implement the basic edit-tools plugin**

Create plugin.json with id basic_edit_tools, version 1.0.0, api_version 1, stage edit, entry plugin.gd.

The context Dictionary contains store, history, viewport, current_frame getter, selected_region getter/setter, status callback, and taxonomy. The plugin translates pointer/keyboard actions into commands but never writes AnnotationStore directly. Dragging updates a transient preview; release executes one command. Escape cancels transient edits.

- [ ] **Step 6: Implement InspectorPanel**

Build controls for region ID, class OptionButton, free-text class LineEdit, kind, confidence, editable track ID, numeric box geometry, fill, and delete. Populate from a deep-copy record. Emit requests to the edit plugin instead of mutating records. Disable box geometry fields for polygons. All controls participate in normal keyboard focus order.

- [ ] **Step 7: Run all edit tests**

Run:

~~~bash
godot --headless --path . --script tests/godot/test_runner.gd
~~~

Expected: all command round trips, invalid-command refusal, pointer actions, and keyboard actions pass.

- [ ] **Step 8: Commit**

~~~bash
git add client/domain/commands client/plugins/edit client/ui/inspector_panel.gd client/ui/inspector_panel.tscn tests/godot
git commit -m "feat: edit regions with reversible commands"
~~~

---

### Task 9: Main application, playback, and timeline

**Files:**
- Create: client/app/main.tscn
- Create: client/app/main.gd
- Create: client/ui/timeline.gd
- Create: client/ui/timeline.tscn
- Create: tests/godot/test_playback.gd
- Create: tests/godot/test_timeline.gd
- Modify: tests/godot/test_runner.gd

**Interfaces:**
- Consumes: plugin registry, source, renderer, edit tools, store, frame cache, viewport, inspector.
- Produces: Main.open_source(path: String), set_frame(index: int), play(), pause(), step(delta: int), seek(index: int); Timeline.configure(frame_count: int), set_current_frame(index), set_verified(index, bool), set_batch_ranges(ranges), and frame_requested signal.

- [ ] **Step 1: Write failing playback-state tests**

Test a 120-frame source:

- initial frame is 0
- next/previous clamp at 119/0
- seek rejects -1 and 120 without changing current frame
- playback advances explicit indices
- timestamp shown equals the manifest entry
- reaching frame 119 pauses rather than wrapping

- [ ] **Step 2: Build the main scene**

Construct the approved fixed layout:

- top toolbar with open, play/pause, previous, next, frame/time, zoom, opacity, undo, redo
- center AnnotationViewport
- right InspectorPanel
- bottom Timeline
- status bar

Use Godot FileDialog for source selection. Selecting a directory opens directly; selecting a video launches python/frame_source.py through ProcessService, displays progress/status, and opens the normalized output only after success.

- [ ] **Step 3: Implement frame-index playback**

Main stores current_frame and uses a Timer at the manifest nominal FPS. Every tick calls set_frame(current_frame + 1). set_frame validates bounds, asks the source for one texture, obtains corrected record, updates viewport/inspector/timeline labels, and prefetches only through the bounded cache. It never uses codec playback time as the annotation index.

- [ ] **Step 4: Write failing timeline tests**

Create tests that configure five frames, mark frames 0 and 2 verified, define a batch range 1–3, and assert the timeline state model returns distinct visual states for current, verified, unverified, and batch membership. Clicking a frame emits its zero-based index.

- [ ] **Step 5: Implement Timeline**

Timeline draws a compact frame strip using cached status arrays rather than creating one button per frame. It supports horizontal scrolling for long sources, click-to-seek, current-frame highlight, verified/unverified color, and batch-range outline.

- [ ] **Step 6: Wire editing and toolbar state**

Selection updates InspectorPanel. Edit commands refresh only the current record and dirty/save indicators. Undo/redo buttons reflect history availability. Opacity updates only render state. Zoom buttons delegate to ViewportTransform. Source errors appear in the status bar without raw stack traces.

- [ ] **Step 7: Run application-state tests and a headless scene load**

Run:

~~~bash
godot --headless --path . --script tests/godot/test_runner.gd
godot --headless --path . --quit-after 2
~~~

Expected: playback/timeline tests pass and main scene loads without parser or missing-node errors.

- [ ] **Step 8: Commit**

~~~bash
git add client/app client/ui/timeline.gd client/ui/timeline.tscn tests/godot
git commit -m "feat: assemble indexed playback and timeline"
~~~

---

### Task 10: Similar-frame propagation and verification workflow

**Files:**
- Create: client/domain/commands/batch_replace_command.gd
- Create: client/services/propagation_service.gd
- Create: client/services/verification_service.gd
- Create: tests/godot/test_propagation.gd
- Create: tests/godot/test_verification.gd
- Modify: client/plugins/edit/basic_edit_tools/plugin.gd
- Modify: client/app/main.gd
- Modify: client/ui/timeline.gd
- Modify: tests/godot/test_runner.gd

**Interfaces:**
- Consumes: current keyframe, corrected records, manifest similarity scores, CommandHistory.
- Produces: PropagationService.find_run(keyframe: int, scores: Array[float], threshold: float = 0.02) -> Vector2i; build_overwrite(store, keyframe, start_frame, end_frame) -> Dictionary; build_merge(store, keyframe, start_frame, end_frame) -> Dictionary; VerificationService.set_verified(frame, value), is_verified(frame), add_batch_marker(marker), next_unverified(current_frame) -> int, and serialize() -> Dictionary.

- [ ] **Step 1: Write failing range and overwrite tests**

Create tests/godot/test_propagation.gd. Use scores whose run around keyframe 2 is frames 1–3 and assert exact boundaries. Build three target records, overwrite frames 1–3 from corrected keyframe 2, and assert:

- target regions equal keyframe regions apart from record frame/time/source fields
- target source remains human_corrected in working state
- model records remain unchanged
- one undo restores every target record
- one redo reapplies every target record

- [ ] **Step 2: Implement BatchReplaceCommand**

Capture before and after maps keyed by integer frame. apply first validates every after record; if any error exists, mutate none. When all pass, replace every corrected record. revert restores every before record. This is one history entry regardless of target range length.

- [ ] **Step 3: Implement range detection and overwrite**

PropagationService.find_run mirrors Python contiguous_run exactly. build_overwrite deep-copies the corrected keyframe regions into every target frame while retaining each target record's frame, time_s, image_size, dataset_id, and corrected source.

- [ ] **Step 4: Write failing merge tests**

Construct target cases for:

- equal non-null track ID with wrong class
- no track ID but same-class IoU 0.7
- no track ID with IoU below 0.5
- unmatched target region
- unmatched keyframe region

Assert track match wins before IoU, matched regions receive keyframe geometry/class, unmatched keyframe regions are added, unmatched target regions remain, and IDs are unique within each target frame.

- [ ] **Step 5: Implement merge and IoU**

Implement box IoU as intersection area divided by union area. Polygon regions without equal track IDs do not receive IoU fallback; they remain unmatched. For each keyframe region, consume at most one target match. When adding a keyframe region whose ID already exists in the target frame, suffix it deterministically with -p<keyframe>-<counter>.

- [ ] **Step 6: Write and implement verification tests**

Test default unverified state, explicit verification, propagated targets reset to unverified, batch marker serialization, and next_unverified search. Search starts after current frame, wraps once, and returns -1 only when all frames are verified.

Create client/services/verification_service.gd with frame_count, a PackedByteArray verified bitmap, and Array[Dictionary] batch markers. Reject out-of-range state changes without mutation.

- [ ] **Step 7: Wire the confirmation workflow**

Add a propagation dialog showing keyframe, detected start/end, threshold 0.02, and merge/overwrite choice. Confirmation creates one BatchReplaceCommand, adds one marker only after command success, marks targets unverified, refreshes timeline, and displays affected-frame count. Cancel changes nothing.

Add Mark Verified and Next Unverified actions. Timeline uses VerificationService state and batch markers.

- [ ] **Step 8: Run propagation and verification tests**

Run:

~~~bash
godot --headless --path . --script tests/godot/test_runner.gd
~~~

Expected: range, merge, overwrite, atomic failure, undo/redo, verification, and navigation tests pass.

- [ ] **Step 9: Commit**

~~~bash
git add client/domain/commands/batch_replace_command.gd client/services/propagation_service.gd client/services/verification_service.gd client/plugins/edit/basic_edit_tools/plugin.gd client/app/main.gd client/ui/timeline.gd tests/godot
git commit -m "feat: propagate and verify similar frame ranges"
~~~

---

### Task 11: Crash-safe autosave and external-process isolation

**Files:**
- Create: client/services/autosave_service.gd
- Create: client/services/process_service.gd
- Create: tests/godot/test_autosave.gd
- Create: tests/godot/test_process_service.gd
- Modify: client/app/main.gd
- Modify: tests/godot/test_runner.gd

**Interfaces:**
- Consumes: corrected snapshot, review-state snapshot, dataset working directory.
- Produces: AutosaveService.configure(directory, interval_seconds), mark_dirty(), save_now(snapshot, review_state), has_unsaved_changes(), recover() -> Dictionary; ProcessService.start(executable: String, arguments: PackedStringArray, result_file: String) -> int, poll() -> Dictionary, cancel().

- [ ] **Step 1: Write failing atomic-save tests**

Test static write helper behavior in a temporary directory:

- writes corrected_autosave.jsonl and review_state_autosave.json
- leaves no .tmp file after success
- replacing an existing autosave yields the new complete content
- simulated pre-rename failure leaves the previous formal autosave unchanged
- recover returns both corrected records and review state

- [ ] **Step 2: Implement atomic write helpers**

AutosaveService serializes snapshots before starting worker work. The worker writes same-directory .tmp files, flushes and closes them, then uses DirAccess.rename_absolute to replace formal files. It reports success or a concise error through a signal:

~~~gdscript
signal save_finished(success: bool, message: String)

func mark_dirty() -> void:
    _dirty = true

func has_unsaved_changes() -> bool:
    return _dirty or _save_in_progress
~~~

Do not access scene nodes or mutate AnnotationStore from the worker thread.

- [ ] **Step 3: Add autosave timer and recovery integration**

Configure a 5-second default timer after a dataset opens. Dirty edits reset pending status but do not create overlapping save threads. Explicit save requests save immediately after any active write finishes. On open, detect matching autosave files and offer Recover or Ignore. On successful save, clear dirty only when no newer edit generation exists.

- [ ] **Step 4: Write failing process-service tests**

Launch the current Python executable with -c and a short script that writes {"success": true, "path": "/tmp/result"} to the requested result file and exits 0. Assert start returns a PID, polling keeps the UI loop responsive, and final result contains success true. Launch a script that writes {"success": false, "error": "fixture failure"} and exits 7; assert the failure is reported without a stack trace.

- [ ] **Step 5: Implement ProcessService**

Use OS.create_process for non-blocking launch and OS.is_process_running for polling. The invoked tool writes a JSON result file containing success plus path or error; read it after the process exits. Do not use OS.execute on the main thread and do not invoke a shell. Track exactly one child process per service instance and clean the result file after reading.

- [ ] **Step 6: Wire video conversion and exit protection**

Main uses ProcessService to invoke:

~~~text
.venv/bin/python python/frame_source.py <video> --output <normalized-directory> --result-file <result-json>
~~~

Disable a second open request while conversion runs, keep playback/UI responsive, and open the output only after exit 0 and validation. A failed conversion leaves the current dataset intact.

On window close, allow immediate exit when clean. When dirty or save is active, show Save and Exit, Exit Without Saving, and Cancel.

- [ ] **Step 7: Run autosave/process tests**

Run:

~~~bash
godot --headless --path . --script tests/godot/test_runner.gd
~~~

Expected: atomic replacement, recovery, edit-generation safety, process success/failure, and exit-state tests pass.

- [ ] **Step 8: Commit**

~~~bash
git add client/services/autosave_service.gd client/services/process_service.gd client/app/main.gd tests/godot
git commit -m "feat: autosave safely without blocking the client"
~~~

---

### Task 12: Diff reports and file-based training handoff

**Files:**
- Create: core/schemas/training-package-v1.schema.json
- Create: python/annotool/diff.py
- Create: python/annotool/package.py
- Create: python/build_update_package.py
- Create: tests/python/test_diff.py
- Create: tests/python/test_package.py
- Create: tests/expected/diff-summary.json
- Create: client/plugins/feedback/file_training_handoff/plugin.json
- Create: client/plugins/feedback/file_training_handoff/plugin.gd
- Create: tests/godot/test_feedback_plugin.gd
- Modify: client/app/main.gd
- Modify: tests/godot/test_runner.gd

**Interfaces:**
- Consumes: immutable model JSONL, corrected JSONL, review state, source manifest.
- Produces: diff_records(model: dict, corrected: dict, tolerance_px: float = 1.0) -> dict; build_diff(model_records, corrected_records) -> dict; aggregate_diff(frame_diffs) -> dict; build_package(manifest_path, model_path, corrected_path, review_state_path, output_root) -> Path; feedback plugin export(context: Dictionary) -> int process ID and export_finished(success, path_or_error).

- [ ] **Step 1: Write failing diff tests**

Create tests/python/test_diff.py with records that isolate:

- one added region
- one deleted region
- one label change
- one box move greater than one pixel
- one box move of exactly one pixel, which is ignored
- one track ID change

Assert per-frame categories and aggregate counts by change category and class. Assert model input dictionaries are unchanged after diffing.

- [ ] **Step 2: Implement diff calculation**

Match regions by ID within a frame. Deleted regions exist only in model; added regions exist only in corrected. For shared IDs compare class, track_id, geometry type, and coordinates. Treat a maximum absolute coordinate difference of 1.0 pixel as unchanged. If geometry type changes, report geometry_changed.

Return:

~~~python
{
    "frame": model["frame"],
    "added": [],
    "deleted": [],
    "label_changed": [],
    "geometry_changed": [],
    "track_changed": [],
}
~~~

Aggregate into total frames changed, category totals, and per-class totals.

- [ ] **Step 3: Write failing package tests**

Build a package under a temporary output root and assert:

- directory name starts with training_update_v1__<dataset>__<model>
- required files exist
- package manifest validates
- corrected JSONL validates
- every checksums.sha256 entry matches actual content
- original model file hash is unchanged
- rebuilding uses a different UTC timestamp or deterministic collision suffix and never overwrites an existing package

- [ ] **Step 4: Implement package schema and builder**

The package manifest requires package_version = 1, dataset_id, source_model_version, annotation_schema_version, created_at_utc, frame_count, verified_frame_count, file entries with relative path/SHA-256/byte count, and diff summary.

Package contents:

~~~text
manifest.json
corrected.jsonl
diff.json
diff_summary.csv
review_state.json
batch_audit.json
checksums.sha256
~~~

Write into a sibling temporary directory, validate all contents, then atomically rename to the final naming convention. Delete only that incomplete temporary package on handled failure.

- [ ] **Step 5: Add the CLI**

Create python/build_update_package.py with four required input/output arguments and one optional process-result argument:

~~~text
--source-manifest
--model-output
--corrected
--review-state
--output-root
[--result-file]
~~~

The CLI also allows --result-file to be omitted for direct terminal use. It prints exactly one success line containing the final package path. When --result-file is present it atomically writes JSON containing success plus path or error. On failure it prints one concise error to stderr and exits nonzero without a traceback.

- [ ] **Step 6: Implement the feedback plugin**

Create plugin.json with id file_training_handoff, version 1.0.0, api_version 1, stage feedback, entry plugin.gd.

The plugin first requests an immediate autosave, then starts build_update_package.py through ProcessService. It disables duplicate export while running, returns progress through status messages, and emits the final path on success. It never performs hashing or directory copying on the main thread.

- [ ] **Step 7: Add feedback integration tests**

Use a generated sample plus corrected fixture to invoke the feedback plugin headlessly. Poll until completion, assert exit 0, validate package contents, and assert pointer/process polling loop iterations occurred while the child process ran. Also invoke with a missing corrected path and assert a readable error while the application remains usable.

- [ ] **Step 8: Run Python and Godot export suites**

Run:

~~~bash
.venv/bin/python -m pytest tests/python/test_diff.py tests/python/test_package.py -v
godot --headless --path . --script tests/godot/test_runner.gd
~~~

Expected: diff, aggregate, package, checksum, plugin success, and plugin failure tests pass.

- [ ] **Step 9: Commit**

~~~bash
git add core/schemas/training-package-v1.schema.json python/annotool/diff.py python/annotool/package.py python/build_update_package.py client/plugins/feedback client/app/main.gd tests
git commit -m "feat: export auditable training handoff packages"
~~~

---

### Task 13: End-to-end smoke test, robustness, and measurements

**Files:**
- Create: tests/smoke/edit_session.gd
- Create: tests/python/test_cli_failures.py
- Create: tests/godot/test_error_recovery.gd
- Create: tests/godot/test_performance.gd
- Create: tests/run_all.sh
- Create: tests/expected/smoke-diff.json
- Modify: tests/godot/test_runner.gd

**Interfaces:**
- Consumes: the full sample and all client/service/plugin APIs.
- Produces: one non-interactive acceptance command and machine-readable performance output for RESULTS.md.

- [ ] **Step 1: Write the failing smoke script**

The script must:

1. open a generated sample
2. select frame 12 and move/resize the drifted box
3. relabel frame 24
4. add the missed frame-36 region
5. delete the hallucinated frame-72 region
6. correct the frame-90 track swap
7. undo and redo one edit
8. propagate keyframe 50 across frames 40–59
9. mark the propagated frames verified after scripted checks
10. autosave
11. export a training package
12. compare resulting diff category/frame expectations

Exit nonzero on the first failed assertion.

- [ ] **Step 2: Add explicit recovery tests**

Test all teacher-listed cases:

- missing manifest
- malformed JSON
- schema-invalid annotation
- missing frame image
- corrupt frame image
- empty regions
- out-of-range seek
- frame/annotation count mismatch
- duplicate plugin ID
- export destination not writable
- cache access across a 10,000-entry synthetic manifest without cache growth beyond its bound

Every expected failure must return a readable message and preserve the prior valid state.

- [ ] **Step 3: Add CLI failure tests**

Invoke sample, frame-source, validator, and package CLIs through subprocess. Assert invalid inputs exit nonzero, stderr contains a concise domain message, and stderr does not contain Traceback.

- [ ] **Step 4: Add performance instrumentation**

Create a Godot headless benchmark that loads the approximately 20-region fixture, performs 300 redraw/transform updates and 300 geometry previews, and prints JSON:

~~~json
{
  "render_updates": 300,
  "mean_update_ms": 0.0,
  "p95_update_ms": 0.0,
  "estimated_fps": 0.0,
  "visible_regions": 20
}
~~~

The implementation fills actual measured values. Fail the benchmark when estimated_fps is below 25. Also measure sample load time and frame-delivery throughput.

- [ ] **Step 5: Create the one-command test runner**

Create tests/run_all.sh:

~~~bash
#!/usr/bin/env bash
set -euo pipefail
.venv/bin/python -m pytest tests/python -v
godot --headless --path . --script tests/godot/test_runner.gd
godot --headless --path . --script tests/smoke/edit_session.gd
~~~

Make it executable.

- [ ] **Step 6: Run the full suite from a clean generated sample**

Remove only the generated /tmp test sample, regenerate it, then run:

~~~bash
./tests/run_all.sh
~~~

Expected: Python tests, Godot tests, smoke session, package validation, and performance threshold all pass.

- [ ] **Step 7: Inspect working-tree output hygiene**

Run:

~~~bash
git status --short
git check-ignore -v .godot sample .venv
~~~

Expected: no generated sample, virtual environment, Godot import, autosave, or export output is staged.

- [ ] **Step 8: Commit**

~~~bash
git add tests
git commit -m "test: verify complete annotation workflow"
~~~

---

### Task 14: Required documentation, reviewer runbook, and submission package

**Files:**
- Create: README.md
- Create: RESULTS.md
- Create: docs/architecture.md
- Create: docs/plugin-api.md
- Create: docs/model-team-interface.md
- Create: docs/reviewer-script.md
- Create: docs/demo-script.md
- Modify: .gitignore if the final generated artifacts reveal an uncovered output path
- Test: tests/python/test_documentation.py

**Interfaces:**
- Consumes: verified commands, measured outputs, keyboard mappings, plugin manifests, package schema.
- Produces: every written artifact and reviewer instruction required by the assignment.

- [ ] **Step 1: Write failing documentation-presence tests**

Create tests/python/test_documentation.py. Assert required files exist and contain:

- README: environment, install, run, sample regeneration, keyboard shortcuts, reviewer test sequence, plugin overview
- RESULTS: MITK, coordinate transform, rendering performance, similarity threshold, batch coverage, manual baseline, boundary check, autosave, two or three failure-analysis entries
- architecture: Mermaid Source → Render → Edit → Export/Feedback → corrected store → training handoff
- model-team interface: schema, fields, coverage, versioning, checksums, refreshed model_output_vN, re-ingestion
- plugin API: manifest fields and one add-plugin walkthrough
- demo script: duration limit and all required shots

- [ ] **Step 2: Write README run commands**

Document exact prerequisite versions, environment creation, dependency installation from requirements.lock, sample generation, frame-source conversion, validation, Godot launch, full test command, corrected-data packaging, and expected outputs. Include the complete keyboard table from the specification and link to docs/reviewer-script.md.

Add a Submission section stating that the final repository is private and that Qingbiao LI (qingbiao.qli@gmail.com) and Tianci Yang (GitHub user PatchouliTC) are added as collaborators. State that secrets, private configuration, build outputs, and large reproducible assets are not committed.

- [ ] **Step 3: Write architecture and plugin API**

docs/architecture.md contains one Mermaid diagram and explains immutable model store, corrected store, shared transform, command history, bounded cache, plugin registry, autosave, and file handoff.

docs/plugin-api.md documents plugin.json fields, each stage's exact methods, failure behavior, API versioning, and a minimal directory example. Verify that following it requires no registry-core modification.

- [ ] **Step 4: Write the model-team interface agreement**

State exactly:

- accepted manifest and annotation schema versions
- zero-based frame alignment
- image coordinate convention
- required/optional region fields
- model_output_vN immutability
- human_corrected output
- package naming and checksums
- required coverage and verified-state reporting
- model team returns a new versioned model_output_vN after retraining
- the reviewer opens the new round as a separate model source against the same source hash

- [ ] **Step 5: Perform and record MITK interaction study**

Use the official MITK interaction/segmentation documentation and repository as the source. RESULTS.md states that selection, move, resize handles, add/remove, fill, focused-tool state, undo/redo, and keyboard access were adopted or adapted to 2D; 3D, volumetric, multi-planar, and advanced contour tooling were dropped because they are outside the assignment.

- [ ] **Step 6: Run and record measurements**

Run the performance test, sample load measurement, frame-delivery measurement, autosave interruption test, batch propagation, manual per-frame labeling baseline, and both batch-boundary checks on the documented machine. Copy actual command outputs and measured values into RESULTS.md. Record two or three real implementation failures and fixes; do not invent incidents.

- [ ] **Step 7: Execute the reviewer script exactly**

Follow docs/reviewer-script.md from a clean checkout without developer-only shortcuts. Verify every required editing operation, keyboard-only path, error message, batch mode, verification state, autosave, export, diff, and handoff package. Fix any discrepancy and rerun the affected automated test before repeating the reviewer step.

- [ ] **Step 8: Prepare the demonstration**

Use docs/demo-script.md to record no more than three minutes:

1. open deterministic sample
2. identify planted defects
3. move/resize, relabel, add, delete, and correct track ID
4. batch-propagate frames 40–59
5. verify and advance
6. export and inspect diff/package

Use subtitles and narration, label accelerated segments, upload privately, and place the private link in README.md.

- [ ] **Step 9: Run final verification**

Run:

~~~bash
./tests/run_all.sh
.venv/bin/python -m pytest tests/python/test_documentation.py -v
git diff --check
git status --short
~~~

Expected: every test passes, no whitespace errors, no secrets/large generated assets/build outputs are staged, and only intended documentation changes remain.

- [ ] **Step 10: Commit**

~~~bash
git add README.md RESULTS.md docs .gitignore tests/python/test_documentation.py
git commit -m "docs: complete reviewer and model-team handoff"
~~~

---

## Specification Coverage Index

| Assignment requirement | Implemented and verified in |
|---|---|
| Versioned contract, dual-runtime validation, immutable model output | Tasks 2 and 5 |
| Deterministic sample and planted defects | Task 3 |
| Arbitrary-video normalization and frame alignment | Task 4 |
| Plugin registry and one plugin per required stage | Tasks 6, 7, 8, and 12 |
| Image rendering, zoom/pan, transforms, picking, polygons, opacity, FPS | Tasks 7 and 13 |
| Select/move/resize/nudge/relabel/add/delete/fill/track correction | Task 8 |
| Undo/redo and schema-invalid edit refusal | Tasks 5 and 8 |
| Keyboard-only editing and shortcut documentation | Tasks 8 and 14 |
| Playback, step, seek, explicit frame/time, bounded memory | Tasks 6 and 9 |
| Similarity threshold and contiguous-run detection | Tasks 4 and 10 |
| Merge/overwrite propagation, batch marker, drift mitigation | Task 10 |
| Verified timeline and next-unverified navigation | Tasks 9 and 10 |
| Autosave, recovery, unsaved prompt, non-blocking IO | Task 11 |
| Corrected JSONL, diff, per-class summary, training package | Task 12 |
| CLI and UI reproducibility | Tasks 4, 11, 12, and 13 |
| Headless smoke, robustness, performance and failure analysis | Tasks 13 and 14 |
| MITK design note, architecture, plugin API, interface agreement | Task 14 |
| Reviewer runbook, private repository instructions, demonstration | Task 14 |

## Final Acceptance Gate

Before calling the assignment complete, run the full suite from a fresh checkout and regenerated sample, replay docs/reviewer-script.md, validate the exported package checksums, and compare every item in Section 18 of the design specification with a passing test or recorded manual check. Do not claim completion while any required item lacks evidence.
