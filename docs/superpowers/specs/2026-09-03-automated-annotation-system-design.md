# Automated Annotation System Design Specification

> **Revision 2 — corrective baseline.** This revision preserves the approved frontend,
> restores direct image opening, and makes the teacher's MITK, componentization, interface,
> maintainability, and evidence requirements binding before any further feature work.

## 0. Binding development charter

This section overrides any conflicting interpretation later in this document or in the
implementation plan. It exists because passing internal tests is not sufficient when the
visible reviewer workflow or the teacher's required boundary has regressed.

The teacher explicitly requires study of MITK's interaction paradigm, a clean componentized
plugin pipeline, documented extension interfaces, human-readable AI-assisted code, and subsequent
extensibility. The precise naming, line-length, protected-node, and acceptance rules below are this
project's approved implementation rules derived from those requirements; they are not presented as
verbatim teacher instructions.

### 0.1 Source-of-truth order

Every design and implementation decision follows this precedence:

1. the teacher's original assignment,
   `docs/Project_6_Automated_Annotation_System_Assignment.md`
2. the user's explicit scope decisions and the approved frontend baseline
3. this design specification
4. the implementation plan
5. task-local implementation choices

A lower-priority source cannot silently remove, rename, move, or reinterpret a higher-priority
requirement. A conflict stops at the design/review gate and requires explicit user approval.
The teacher's assignment is a read-only requirement source, not an implementation file.

### 0.2 MITK-first 2D interaction style

Before changing edit behavior, study the relevant manual-interaction patterns in the official
[MITK repository](https://github.com/MITK/MITK) and its interaction/segmentation documentation.
Adopt only the 2D behaviors that serve this assignment:

- keep a visible tool palette and show the active tool as pressed
- make tool switching explicit; `Select` is the safe default
- treat mouse press, move, and release as one interaction
- show a transient preview while dragging and commit one undoable command on release
- show selection clearly before move, resize, relabel, fill, or delete
- provide keyboard access and application-wide bounded undo/redo
- cancel transient state safely when the tool, frame, source, or focus changes

MITK is a design reference, not a dependency. Volumetric, 3D, multi-planar, advanced contour,
and full MITK behavior remain outside scope. Polygon drawing and vertex editing are optional in
the assignment and are deliberately excluded from the first version.

### 0.3 Structured components and explicit interfaces

- Each scene, script, service, command, and plugin has one primary responsibility.
- UI scenes emit intent; domain commands validate and mutate; services own reusable state or IO;
  plugins implement documented stage contracts. UI nodes do not absorb domain logic.
- Every public boundary documents exact method names, argument and return types, emitted signals,
  lifecycle, validation failures, and ownership of mutable state.
- Required dependencies are injected through activation context or explicit setters. Components
  communicate by interfaces and signals, not hidden sibling-node lookups.
- New plugins are added by adding a plugin directory and manifest; the registry core is not
  edited for each plugin.
- Interface version 1 is stabilized before `docs/plugin-api.md` is accepted. Later incompatible
  changes require a version bump and compatibility tests.
- Existing large scripts are not rewritten merely for style. Extract a focused component only
  when a required feature exposes a stable responsibility and test boundary.

### 0.4 Maintainability and code style

- Preserve the approved scene-node contract and existing behavior unless the active requirement
  explicitly changes them.
- Avoid broad refactors inside feature tasks; compose existing scenes, services, commands, and
  plugins first.
- Use `snake_case` for files, functions, signals, and variables; use `PascalCase` for named classes
  and scene nodes; use tabs in GDScript and typed public boundaries.
- Keep new or modified code lines at 100 characters or fewer where practical. Do not run a
  repository-wide formatter to satisfy a local change.
- Show concise, actionable errors in the UI and keep raw stack traces in developer output only.
- Keep model records immutable, frame indices zero-based, and image-pixel coordinates explicit.
- Any interface change updates its contract tests and documentation in the same reviewed task.

### 0.5 Scope, testing, and acceptance discipline

- Required teacher deliverables take priority over optional features. No optional extension starts
  while a required phase gate is incomplete.
- Every behavior-bearing change starts with a failing test and ends with focused tests, the full
  relevant suite, and product-level acceptance evidence.
- A green automated suite proves only the assertions it contains. It cannot overrule the approved
  visible workflow or replace manual reviewer checks.
- A phase is complete only when its code, tests, documentation, manual reviewer steps, and required
  artifacts all pass and are linked in the requirements traceability table.
- Model training/inference, cloud services, accounts, collaboration, Web/mobile clients, 3D,
  optical flow, and unrelated polish remain outside the first-version boundary.

### 0.6 Protected product contract

The following visible shell is protected from deletion, renaming, or relocation without explicit
user approval:

- top toolbar: `Open`, `Save`, `Undo`, `Redo`, `Export`
- left tool panel: `Select`, `Move`, `Box`, `Fill`, `Delete`
- center: the real `AnnotationViewport`
- right: `InspectorPanel`
- bottom: previous, play/pause, next, frame/time display, and `Timeline`
- status bar: current tool, source state, save state, and recoverable errors

Buttons may be disabled until their required backend exists, but they remain visible. Tool buttons
are mutually exclusive, the active button remains pressed, and `Select` is active after startup.

The `Open` action must accept these three teacher-aligned source forms:

- PNG/JPG/JPEG: open as a one-frame source at frame 0; use an empty region list when no annotation
  accompanies the image
- normalized image-sequence directory: open its manifest and annotations through the existing
  source plugin
- video: normalize asynchronously through `ProcessService`, then open the resulting frame source

An invalid replacement source must not discard the currently loaded valid dataset. Changes to
`main.tscn` or this source-opening contract require structure tests, direct-image and directory-open
tests, and a manual 1280 x 800 visual check.

### 0.7 Mandatory recovery gate

The current Task 9 implementation is technically integrated but product-rejected: it removed the
protected left tool panel and top-level `Save`/`Export` controls, and it rejects a direct image file.
No Task 10 or later feature work may begin until Task 9R restores those behaviors and the Part 1
closure gate confirms all mandatory Part 1 artifacts.

## 1. Purpose

Build a reliable, local, single-user 2D annotation application that lets a reviewer open a single
image, an image sequence, or a decoded video; load model-produced annotations when present; correct
those annotations; propagate a keyframe correction across a contiguous run of similar frames;
verify the result; and export a versioned training-update package.

The product is an annotation and feedback tool. It does not train or run a perception model.

## 2. Binding scope

### 2.1 Included

- A Godot 4.x desktop client implemented in GDScript.
- A Python 3.10+ support toolchain for deterministic sample generation, video-to-frame decoding, schema validation, similarity calculation, and export verification.
- One local dataset open at a time.
- Single-image sources, image-sequence sources, and arbitrary FFmpeg-supported videos represented
  through the same indexed-frame source contract.
- Rendering of box and polygon regions over a 2D image.
- Complete box editing: select, move, resize, keyboard nudge, relabel, track-ID correction, add, delete, and fill.
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

The current shell has Python 3.14.7. The Godot GUI reports 4.7.2-stable, but its executable is not
yet available on the shell path; FFmpeg is also unavailable on the shell path. Resolving and
documenting those executable paths is an environment acceptance task, not a reason to change the
architecture or count skipped checks as passing.

## 4. User workflow

1. The reviewer selects a PNG/JPG/JPEG image, a normalized image-sequence directory, or a video.
2. A single image becomes a one-frame source. If the input is a video, the Python frame-source tool
   decodes it to an indexed image sequence and writes a manifest. The client then treats every
   accepted input through the same indexed-frame contract.
3. The client validates the manifest and annotation records. Invalid input produces a readable error and does not replace the currently open dataset.
4. The first frame appears with immutable model annotations overlaid.
5. The reviewer navigates, plays, pauses, seeks, and corrects regions.
6. Each accepted edit creates a command, updates the corrected working copy, marks the frame dirty, and can be undone/redone.
7. On a keyframe, the reviewer can inspect the contiguous similar-frame run and propagate the corrected regions using merge or overwrite.
8. Propagated target frames remain unverified until the reviewer checks them.
9. Autosave writes the corrected working state atomically.
10. Export validates all corrected records, creates JSONL annotations and diff reports, and writes a versioned training-update package.

## 5. UI boundary

The application has one fixed, protected main layout:

- Top toolbar: Open, Save, Undo, Redo, and Export.
- Left tool panel: mutually exclusive Select, Move, Box, Fill, and Delete modes.
- Center viewport: image, region overlays, selected state, resize handles, and pan/zoom interaction.
- Right inspector: selected region ID, class, kind, confidence, track ID, geometry values,
  annotation opacity, relabel controls, and validation messages.
- Bottom transport and timeline: previous, play/pause, next, explicit frame/time display, frame
  positions, current frame, similar-run indication, batch marker, and verified/unverified state.
- Status bar: active tool, autosave state, source state, and non-fatal errors.

Save and Export remain visible before their later-stage implementations and are disabled with a
clear status until their services are available. Resize remains a selected-box handle interaction;
polygon drawing does not appear as a first-version tool.

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

- frame-unique `id`
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

A dedicated `single_image_source` plugin adapts PNG/JPG/JPEG files to the same Source-stage
interface with one manifest entry at frame 0. It returns one valid empty annotation record when no
annotation accompanies the image. The existing `image_sequence_source` continues to own normalized
directories; neither plugin changes the canonical annotation schema.

When a video is selected in the client, the Source plugin launches this tool as a child process and monitors it without blocking the UI. Progress and failure are reported in the status bar. The normalized source replaces the current source only after conversion and validation succeed.

Godot selects the source plugin from the candidate path before committing replacement state. Source
plugins expose the same indexed-frame interface, load through the bounded least-recently-used cache,
and never load a full sequence into memory.

Out-of-range seeks, missing frame files, corrupt images, and empty annotations produce visible recoverable errors.

## 10. Editing model

All persistent annotation changes use commands:

- select is transient and not stored in undo history
- move region
- resize box
- keyboard nudge
- relabel region
- change track ID
- add box
- delete region
- toggle fill
- propagate batch

The edit plugin exposes one explicit active mode from `select`, `move`, `box`, `fill`, and `delete`.
Changing mode cancels any transient preview, updates the pressed state in `ToolPanel`, and does not
itself create a history entry. `ToolPanel` emits intent only; the edit plugin owns tool behavior and
produces domain commands.

Each command implements `apply`, including validation before mutation, and `revert`. Undo/redo stores the last 200 accepted commands. A new command after undo clears the redo branch.

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

- `single_image_source`
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
- protected toolbar, tool-panel, inspector, transport, timeline, and status-bar nodes
- mutually exclusive edit-tool state and transient-preview cancellation
- direct PNG/JPG/JPEG opening, normalized-directory opening, and transactional failure recovery

The headless smoke test performs an end-to-end scripted session: load sample, select a frame, move/resize/relabel/add/delete, undo/redo, propagate a keyframe, verify frames, autosave, export, and compare generated diff/package expectations.

Manual reviewer testing covers the protected layout at 1280 x 800, direct-image and sample-directory
opening, pointer interaction, keyboard-only interaction, focus traversal, visual correctness,
playback, error messages, and the final handoff workflow.

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
- the protected UI shell and all three source-opening routes pass their automated and manual checks
- every teacher requirement has a traceability row linking implementation, automated evidence,
  manual evidence where required, status, and the next corrective task

Part 1 is complete only when the schema and validators, deterministic sample, video frame source,
plugin registry, working Source/Render/Edit/Feedback plugins, architecture diagram, plugin API,
README, and zero-error sample validation are all present and verified. Later implementation does
not retroactively waive a missing Part 1 artifact.

Anything outside this specification is deferred until after the assignment has been accepted.
