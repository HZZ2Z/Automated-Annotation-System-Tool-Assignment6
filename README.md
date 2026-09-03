# Automated Annotation System

Godot client and Python tooling for a versioned, plugin-based surgical-image annotation workflow. This repository currently claims the assignment's **Part 1 foundation only**: reproducible inputs, shared contracts, source normalization, plugin discovery, one working plugin per required stage, and a runnable integration shell.

## Development principles

These rules come before feature work and are the guardrails for every later part:

1. **Use MITK as the interaction reference.** Preserve its deliberate select/edit, visible state, cancellation, and undo/redo ideas when translating medical-image interaction to a 2D video tool. Do not copy unrelated 3D functions.
2. **Keep code structured by ownership.** Scenes compose UI, domain objects own annotation state and commands, services own transforms/cache/process boundaries, and plugins own replaceable stage behavior.
3. **Maintain clear interfaces.** Cross-module calls go through the documented Source, Render, Edit, and Export/Feedback contracts; the application must not depend on a plugin's private fields.
4. **Prefer maintainable, testable changes.** Each state-changing edit is one validated command, inputs and outputs are defensively copied, and failures are readable and isolated.
5. **Respect the Part 1 boundary.** This checkpoint does not claim batch propagation, autosave, diff generation, training submission, performance measurements, or the final MITK design evaluation. Save and Export remain visibly disabled in the UI until their later backends are integrated.

The detailed topology is in [docs/architecture.md](docs/architecture.md), and the stable extension contract is in [docs/plugin-api.md](docs/plugin-api.md).

## Supported environment

The checked reference environment is:

- **Godot 4.7.2-stable**, official build `ed1daf0bf`, using GDScript and the GL Compatibility renderer.
- **Python 3.14.7**; the package supports Python `>=3.10,<3.15`.
- **FFmpeg 6.1+**, with both `ffmpeg` and `ffprobe` on `PATH`. FFmpeg is mandatory for video integration tests and video normalization.
- Python packages pinned in `requirements.lock`.

An equivalent environment is acceptable only when its versions and commands are documented. A skipped FFmpeg test is an incomplete environment check, not a pass.

## Quick start

Run every command from the repository root.

```bash
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements.lock
.venv/bin/python -m pip install --no-deps -e .
```

Point `GODOT_BIN` at the official Godot 4.7.2 executable installed on the reviewer machine. If `godot` already resolves to that build, use `export GODOT_BIN=godot`.

```bash
export GODOT_BIN=/absolute/path/to/Godot_v4.7.2-stable_linux.x86_64
"$GODOT_BIN" --version
python3 --version
ffmpeg -version
ffprobe -version
```

The Godot version output must begin with `4.7.2.stable`. Both FFmpeg commands must succeed before the full test result is accepted.

On a machine without administrator access, Conda can provide the pinned video tools inside this checkout without changing the Python virtual environment:

```bash
CONDA_PKGS_DIRS="$PWD/.tools/conda-pkgs" conda create --yes \
  --prefix "$PWD/.tools/ffmpeg" --override-channels --channel conda-forge \
  ffmpeg=6.1.2
export PATH="$PWD/.tools/ffmpeg/bin:$PATH"
ffmpeg -version
ffprobe -version
```

`.tools/` is ignored and must not be committed.

## Generate and validate the required sample

The output directory must not already exist. Seed `6006` deterministically produces 120 frames at 640×360, model annotations, manifest metadata, hashes, and a defect ledger.

```bash
.venv/bin/python python/make_sample_input.py --output sample/assignment_v1 --seed 6006
.venv/bin/python python/validate_annotations.py sample/assignment_v1/model_output.jsonl
.venv/bin/python python/validate_annotations.py \
  --schema dataset-manifest-v1.schema.json sample/assignment_v1/manifest.json
```

The generator must print `Validation errors: 0`; both explicit validators must exit with status 0 and print no validation errors. The planted cases are drifted regions, a wrong class, a missed region, a hallucinated region, a track-id swap, and the near-identical frame run 40–59.

To normalize any FFmpeg-readable video into the same indexed directory contract:

```bash
.venv/bin/python python/frame_source.py input.mp4 --output sample/normalized_video
```

The client then treats `sample/normalized_video` exactly like the generated image sequence. It does not use codec playback as annotation truth; manifest frame indices and timestamps are authoritative.

## Run tests

```bash
.venv/bin/python -m pytest tests/python -q
"$GODOT_BIN" --headless --path . --script tests/godot/test_runner.gd
```

Accept the Python gate only when the summary has no failures and no skipped FFmpeg checks. The Godot suite intentionally opens malformed image fixtures to verify recoverable errors, so engine decoder warnings may appear; the required final line is `PASS: complete Godot test suite` and the process exit status must be 0.

## Run the client

```bash
"$GODOT_BIN" --editor --path .
```

Press Run in Godot, then use this Part 1 reviewer path:

1. Press **Open** and select a standalone image (`.png`, `.jpg`, or `.jpeg`). Confirm it appears as `Frame 0 (1 total)`.
2. Activate Select, Move, Box, Fill, and Delete. Exactly one left-side tool remains pressed; switching tools cancels an unfinished preview.
3. Press **Open** again and select the normalized directory `sample/assignment_v1`. Confirm frame 0 and its model regions appear, the Inspector stays on the right, and playback/timeline controls stay at the bottom.
4. Try opening a corrupt or unsupported file. The status bar must explain the rejection and the previously loaded source must remain usable.
5. Confirm the top row still contains Open, Save, Undo, Redo, and Export. Save and Export are intentionally disabled at the Part 1 boundary.

### Current keyboard shortcuts

| Action | Shortcut |
|---|---|
| Cycle region selection forward/backward | `Tab` / `Shift+Tab` |
| Move selected region by 1/5/10 image pixels | `Arrow` / `Shift+Arrow` / `Ctrl+Shift+Arrow` |
| Resize selected box by 1/5/10 image pixels | `Alt+Arrow` / `Alt+Shift+Arrow` / `Alt+Ctrl+Shift+Arrow` |
| Start keyboard box creation | `A` |
| Confirm keyboard box | `Enter` |
| Delete selected region | `Delete` or `Backspace` |
| Undo / redo | `Ctrl+Z` / `Ctrl+Shift+Z` |
| Cancel current preview or gesture | `Escape` |
| Temporary viewport pan | hold `Space` and drag, or middle-drag |
| Viewport zoom | mouse wheel or bottom `Zoom −` / `Zoom +` controls |

Text fields consume typing while focused, so editing an Inspector value does not trigger canvas shortcuts.

## Plugin overview

The registry scans `client/plugins` at startup and validates every manifest against API version 1.

- Source: `image_sequence_source` reads normalized directories; `single_image_source` adapts PNG/JPG/JPEG to one indexed frame.
- Render: `canvas_region_renderer` draws the image-space regions through the shared viewport transform.
- Edit: `basic_edit_tools` owns Select/Move/Box/Fill/Delete intent and submits validated commands to bounded history.
- Export/Feedback: `file_training_handoff` validates a corrected snapshot and writes atomic `human_corrected` JSONL. Its UI button is not enabled in Part 1.

Adding a plugin requires a new plugin directory and `plugin.json`; it must not require edits to the registry. See [docs/plugin-api.md](docs/plugin-api.md) for the exact methods, lifecycle, ownership rules, and compatibility test.

## Repository layout

```text
client/                  Godot scenes, domain objects, services, and plugins
core/                    JSON Schemas and shared taxonomy
python/                  sample generation, validation, and video normalization
tests/godot/             headless Godot contract and integration tests
tests/python/            Python contract, sample, video, and documentation tests
docs/                    architecture, plugin API, traceability, and assignment
```

Generated samples, Godot imports, virtual environments, and large assets are not source artifacts and must not be committed. The Part 1 evidence ledger is [docs/requirements-traceability.md](docs/requirements-traceability.md).
