# Automated Annotation System Design Specification

## 1. Purpose

Build a reliable, local, single-user 2D annotation application that lets a reviewer load model-produced annotations for an image sequence or decoded video, correct those annotations, propagate a keyframe correction across a contiguous run of similar frames, verify the result, and export a versioned training-update package.

The product is an annotation and feedback tool. It does not train or run a perception model.

## 2. Binding scope

### 2.1 Included

- A Godot 4.x desktop client implemented in GDScript.
- A Python 3.10+ support toolchain for deterministic sample generation, video-to-frame decoding, schema validation, similarity calculation, and export verification.
- One local dataset open at a time.
- Image-sequence sources and arbitrary FFmpeg-supported videos converted into the same indexed image-sequence representation.
- Rendering of box and polygon regions over a 2D image.
- Complete box editing: select, move, resize, keyboard nudge, relabel, add, delete, and fill.
- Polygon display, selection, move, delete, relabel, and fill. Polygon vertex editing and polygon drawing are not included.
- Bounded undo/redo for every annotation-changing action.
- Frame playback, pause, seek, single-step, explicit frame index, and explicit timestamp.
- Bounded frame caching so long sources are not loaded into RAM at once.
- Consecutive-frame similarity scoring using downsampled grayscale mean absolute difference.
- Keyframe propagation with explicit overwrite and merge modes.
- Per-frame verified/unverified state, timeline indication, and advance-to-next-unverified behavior.
- Crash-safe autosave, unsaved-change protection, corrected annotation export, diff generation, and a versioned file-based training handoff package.
- A directory-discovered plugin registry with one working plugin for each required stage: Source, Render, Edit Tools, and Export/Feedback.
- Python tests, Godot headless tests, an end-to-end scripted smoke test, measurements, documentation, architecture diagram, and a reviewer runbook.

### 2.2 Excluded

- Model training, inference, weight management, or evaluation.
- Real-time camera ingestion.
- Cloud services, databases, user accounts, or multi-user collaboration.
- A web or mobile client.
- 3D annotations or volumetric medical imaging.
- Full MITK reproduction.
- Polygon vertex editing or polygon drawing.
- Optical flow, learned similarity, interpolation, or automatic tracking.
- Multiple simultaneous datasets.
- Plugin hot reload or remote plugin installation.
- Import/export format proliferation. The canonical annotation export is JSONL; the diff report is JSON plus CSV summary.
- A mock HTTP training service. The selected assignment-compliant handoff is file based.

## 3. Fixed technical direction

- Client: Godot 4.x, GDScript, Compatibility renderer. The exact installed Godot 4.x build is pinned in `README.md` and project metadata before implementation begins.
- Python: Python 3.10 or newer, with the tested version pinned in `README.md` and `pyproject.toml`.
- Video decoding: FFmpeg invoked by `python/frame_source.py`.
- Image generation and similarity: NumPy and OpenCV headless.
- Contract validation: JSON Schema Draft 2020-12 and Python `jsonschema`.
- Python testing: pytest.
- Godot testing: repository-owned headless GDScript test runner; no test framework plugin is required.
- Documentation diagrams: Mermaid committed as text.

The current development machine has Python 3.14.7 but does not yet have Godot or FFmpeg. Installing and pinning those prerequisites is an implementation setup task, not a reason to change the architecture.

## 4. User workflow

1. The reviewer selects an image-sequence directory or a video.
2. If the input is a video, the Python frame-source tool decodes it to an indexed image sequence and writes a manifest. The client then treats it identically to an existing image sequence.
3. The client validates the manifest and annotation records. Invalid input produces a readable error and does not replace the currently open dataset.
4. The first frame appears with immutable model annotations overlaid.
5. The reviewer navigates, plays, pauses, seeks, and corrects regions.
6. Each accepted edit creates a command, updates the corrected working copy, marks the frame dirty, and can be undone/redone.
7. On a keyframe, the reviewer can inspect the contiguous similar-frame run and propagate the corrected regions using merge or overwrite.
8. Propagated target frames remain unverified until the reviewer checks them.
9. Autosave writes the corrected working state atomically.
10. Export validates all corrected records, creates JSONL annotations and diff reports, and writes a versioned training-update package.

## 5. UI boundary

The application has one fixed main layout:

- Top toolbar: open, play/pause, previous/next frame, frame/time display, zoom controls, annotation opacity, undo, and redo.
- Center viewport: image, region overlays, selection state, resize handles, and pan/zoom interaction.
- Right inspector: selected region ID, class, kind, confidence, track ID, geometry values, fill control, add/delete actions, and validation messages.
- Bottom timeline: frame positions, current frame, similar-run indication, batch marker, and verified/unverified state.
- Status bar: active tool, autosave state, source state, and non-fatal errors.

No docking system, theming system, animation framework, or alternative layout is included.

## 6. Coordinate and rendering model

Image coordinates are authoritative:

- Origin: image top-left.
- Positive x: right.
- Positive y: down.
- Unit: image pixels.
- Box: `[x, y, width, height]`, with width and height strictly greater than zero.
- Polygon: at least three distinct vertices. The first vertex is not repeated; rendering closes the polygon implicitly.

One `ViewportTransform` service owns the forward and inverse mappings between image and viewport coordinates. Rendering, hit testing, dragging, resize handles, and keyboard geometry updates use this same transform.

The renderer preserves aspect ratio and accounts for letterboxing. Regions are drawn with class color, label, optional confidence, selected state, and configurable opacity. Boxes and polygons can be filled. Polygon fill always closes the last point to the first point, which covers approximately closed model contours without requiring vertex editing.

Rendering uses one custom canvas drawing surface, caches class styles, and redraws only when the frame, annotation state, selection, opacity, or viewport transform changes. It does not create a separate scene subtree for every region.

The performance acceptance target is at least 25 FPS while zooming or dragging on the shipped sample or benchmark fixture with approximately 20 visible regions on the documented test machine.

## 7. Data contract

### 7.1 Dataset manifest

The manifest contains:

- `schema_version`
- `dataset_id`
- `source_name`
- `source_sha256`
- `width`
- `height`
- `frame_count`
- `nominal_fps`
- ordered frame entries with `frame`, `time_s`, and relative image path
- `model_version`
- `taxonomy_version`

Frame indices are zero-based, contiguous, and identical across the manifest, annotation JSONL, UI, diff report, and training package.

### 7.2 Per-frame annotation record

Each record contains:

- `schema_version`
- `dataset_id`
- `source`
- `frame`
- optional `time_s`
- `image_size: [width, height]`
- `regions`

Each region contains:

- dataset-unique `id`
- non-empty `class`
- `kind` from the documented taxonomy
- exactly one geometry: `box` or `polygon`
- optional `conf` in `[0, 1]`
- optional nullable `track_id`
- optional `filled` boolean

The model source is versioned as `model_output_vN`. Corrected exports use `source: "human_corrected"`. Model records are loaded into an immutable store and never overwritten.

### 7.3 Review state

Tool-specific review metadata is stored separately from the shared annotation contract. It contains:

- per-frame verified state
- batch markers
- keyframe index
- propagation mode
- propagation range
- similarity threshold

This separation keeps training annotations small and prevents UI workflow fields from becoming mandatory model-team fields.

### 7.4 Validation parity

The canonical schema is stored under `core/schemas`. Python performs full JSON Schema validation. Godot performs the equivalent load-time and edit-time domain checks. Both runtimes execute the same valid and invalid JSON fixtures so constraint drift is detected by tests.

An invalid record is rejected with a field-specific message. Loading invalid data never crashes the UI or discards the currently open valid dataset.

## 8. Deterministic sample

`python/make_sample_input.py` produces the required sample from fixed seed `6006`:

- 120 frames
- 640 x 360 pixels
- nominal 30 FPS
- moving colored shapes representing instrument and anatomy classes
- approximately 20 visible regions in the performance fixture
- a contiguous near-identical segment at frames 40 through 59

The model-output annotations contain planted defects with a machine-readable expected-defects manifest:

- drifted geometry on multiple frames
- a wrong class label
- one missed region
- one hallucinated region
- one track-ID swap

Two runs with the same seed must produce the same manifest, annotations, expected-defects manifest, and frame-content hashes.

Generated binary sample frames are reproducible artifacts and are not committed if their size is material. The generator and small fixtures are committed.

## 9. Frame source

`python/frame_source.py` accepts a video path and output directory. It uses FFmpeg to produce ordered frame images and derives explicit frame timestamps for the manifest. A validation pass rejects missing frames, duplicate indices, non-contiguous indices, invalid dimensions, or annotation/frame-count mismatch.

When a video is selected in the client, the Source plugin launches this tool as a child process and monitors it without blocking the UI. Progress and failure are reported in the status bar. The normalized source replaces the current source only after conversion and validation succeed.

The Godot source plugin consumes only the normalized manifest representation. It loads frames on demand through a bounded least-recently-used cache and never loads the full source into memory.

Out-of-range seeks, missing frame files, corrupt images, and empty annotations produce visible recoverable errors.

## 10. Editing model

All persistent annotation changes use commands:

- select is transient and not stored in undo history
- move region
- resize box
- keyboard nudge
- relabel region
- add box
- delete region
- toggle fill
- propagate batch

Each command implements validation, execute, and undo. Undo/redo stores the last 200 accepted commands. A new command after undo clears the redo branch.

Relabeling provides both the configured taxonomy list and a free-text entry. A non-empty free-text value is accepted and preserved exactly after schema validation.

Pointer dragging may update a transient preview, but mouse release commits one command. Schema-invalid commands are refused before mutation and show an explanatory message.

Keyboard reachability is mandatory:

- Tab/Shift+Tab cycles selectable controls and region list items.
- Arrow keys nudge the selected region by 1 pixel.
- Shift+Arrow nudges by 5 pixels.
- Ctrl+Shift+Arrow nudges by 10 pixels.
- Alt+Arrow resizes a selected box by 1 pixel; Shift and Ctrl+Shift apply 5 and 10 pixels.
- Enter confirms add/relabel actions.
- Delete removes the selected region.
- Ctrl+Z/Ctrl+Shift+Z perform undo/redo.
- A documented shortcut opens the add-box workflow without pointer input.

## 11. Playback and frame cache

Playback is frame-index driven rather than codec-time driven. The manifest maps each frame index to its timestamp. Play/pause advances through explicit indices; previous, next, and seek select explicit indices.

The client displays current frame index, total frame count, and timestamp. A bounded cache retains the current frame and a small neighboring window. Cache size is configurable but has a finite documented default.

## 12. Similarity and batch propagation

Consecutive similarity is computed by:

1. resize each image to 64 x 64
2. convert to grayscale
3. compute normalized mean absolute pixel difference

The default threshold is `0.02`. Scores and threshold are recorded so the shipped sample measurement is reproducible. The sample generator ensures frames 40 through 59 form a contiguous candidate run and that its boundaries are distinguishable at the documented threshold.

The reviewer explicitly initiates propagation from the current keyframe and confirms the target range and mode.

Overwrite semantics:

- replace all regions in every target frame with a deep copy of the corrected keyframe regions

Merge semantics:

- match first by equal non-null track ID
- otherwise match same-class regions by highest IoU above `0.5`
- matched target regions receive the keyframe class and geometry
- unmatched keyframe regions are added with frame-unique region IDs
- unmatched existing target regions remain

Every target frame receives data directly from the keyframe, never from the previous propagated frame. This prevents propagation-chain drift. Propagated frames are marked unverified. The timeline shows the batch range and the next-unverified action selects the first later unverified frame, wrapping once to the beginning.

## 13. Persistence, diff, and handoff

Corrected working data is autosaved after changes on a documented timer and on explicit save. Save writes a temporary file in the same directory, closes it, and atomically renames it over the prior autosave. Save failure preserves in-memory edits and dirty state. Exit with dirty state requires explicit confirmation.

Autosave, export, hashing, and package creation run outside the UI update path. Completion and errors return to the main thread as messages; no file operation may stall pointer interaction or playback.

Export writes:

- corrected annotation JSONL
- per-frame diff JSON
- aggregate diff CSV
- review-state and batch-audit JSON
- package manifest
- SHA-256 checksums

Diff categories are added, deleted, label changed, geometry changed, and track ID changed. Geometry comparison uses a documented one-pixel tolerance.

The aggregate diff reports totals by change category and by class.

The file-based training handoff package uses the naming convention `training_update_v1__<dataset_id>__<model_version>__<UTC timestamp>` and contains the corrected annotations, diff reports, audit data, manifest, and checksums. Package creation runs without blocking UI input. Success shows the final local path. This is the only training-delivery mechanism in the first version.

The same validation, diff, and package-building services are exposed through Python command-line entry points. A saved corrected working copy can therefore be validated and packaged without opening the UI, while the normal reviewer workflow performs the same operations in the client.

## 14. Plugin architecture

The client scans `client/plugins/*/plugin.json` at startup. A plugin manifest contains `id`, `version`, `api_version`, `stage`, and `entry`. Unknown stages, incompatible API versions, duplicate IDs, missing entries, and script load failures are reported without crashing startup.

Required extension points:

- Source: opens a normalized source and provides indexed frames plus model annotations.
- Render: draws the image and annotations using the shared viewport transform.
- Edit Tools: registers the required interaction tools and produces edit commands.
- Export/Feedback: validates and writes the training handoff package.

The initial working plugins are:

- `image_sequence_source`
- `canvas_region_renderer`
- `basic_edit_tools`
- `file_training_handoff`

Adding a new plugin requires adding a plugin directory and does not require modifying the registry core.

## 15. Error handling

Expected user and data errors are shown as concise messages, never raw stack traces:

- missing or invalid manifest
- schema-invalid annotation
- missing or corrupt frame
- annotation/frame mismatch
- empty annotation list
- out-of-range seek
- plugin load failure
- autosave or export failure
- invalid edit geometry

The currently loaded valid dataset remains usable when opening a replacement source fails.

## 16. Test strategy

Python tests cover:

- schema valid and invalid fixtures
- deterministic sample hashes
- planted defect manifest
- video/frame manifest alignment
- similarity scores and contiguous range detection
- export and diff correctness
- training-package manifest and checksums

Godot headless tests cover:

- schema/domain validation parity fixtures
- forward/inverse coordinate transforms
- transformed hit testing
- every command's execute/undo/redo behavior
- bounded command history
- merge and overwrite semantics
- verification navigation
- plugin discovery and plugin failure isolation
- frame-cache bounds
- autosave recovery behavior

The headless smoke test performs an end-to-end scripted session: load sample, select a frame, move/resize/relabel/add/delete, undo/redo, propagate a keyframe, verify frames, autosave, export, and compare generated diff/package expectations.

Manual reviewer testing covers pointer interaction, keyboard-only interaction, visual correctness, playback, error messages, and the final handoff workflow.

## 17. Documentation and measurements

The repository includes:

- `README.md`: environment, install, sample regeneration, run commands, keyboard table, and reviewer script
- `RESULTS.md`: MITK interactions adopted/adapted/dropped, rendering approach, measurements, batch coverage, boundary checks, autosave behavior, and failure analysis
- architecture diagram
- plugin API document
- model-team interface agreement
- demonstration video script and link

The model-team interface agreement states the schema and taxonomy versions, required fields, coverage, package naming and checksums, what refreshed `model_output_vN` is returned after retraining, and how that new model-output round is re-ingested without replacing prior rounds.

Recorded measurements include load time, frame delivery/playback rate, drag/zoom FPS with approximately 20 regions, editing response time, batch coverage, a measured manual-per-frame labeling baseline, propagated-result checks at both batch boundaries, and autosave behavior. Measurement procedure and test-machine details accompany each result. Failure analysis documents two or three concrete bugs encountered and how they were fixed.

The final demonstration is no longer than three minutes and follows the assignment sequence: open sample, expose planted defects, correct each required defect type, propagate the similar-frame range, verify, export, and show the training handoff package.

## 18. Completion criteria

The project is complete only when:

- a clean environment can follow the README to generate and validate the sample and launch the client
- model output remains byte-for-byte unchanged through an edit/export session
- all required box edits, polygon display/fill, keyboard access, and undo/redo work
- zoomed and panned hit testing remains correct
- playback, step, seek, frame index, and timestamp align with the manifest
- long sources use bounded memory through the frame cache
- merge and overwrite match the documented semantics and are undoable
- verified/unverified navigation and timeline indication work
- autosave is atomic and a failed save cannot discard in-memory edits
- export, diff, and package counts agree and all package checksums validate
- one working plugin exists for every required extension point and registry failures are isolated
- all Python, Godot headless, and smoke tests pass
- `RESULTS.md`, reviewer runbook, interface agreement, architecture diagram, and demonstration are complete
- the private submission repository contains no credentials, private configuration, build outputs, or large reproducible assets, and the required reviewers can be added as collaborators

Anything outside this specification is deferred until after the assignment has been accepted.
