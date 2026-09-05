# Assignment Results

## Part 2.1 Display status

Part 2.1 is `PASS` on the measured host. This result covers the image/viewport coordinate pipeline, box and polygon overlays, class colors, labels, confidence text, overlay opacity, selection under the same transform, the shipped complex-polygon example, and the required smoothness measurement. Part 2.2 Editing and Part 2.3 interaction-fidelity are evaluated separately below; neither changes the measured Part 2.1 rendering result.

## Coordinate pipeline

`ViewportTransform` owns the only image-to-viewport camera. For image size `I`, viewport rectangle `V`, user zoom `z`, and viewport-space pan `p`:

```text
fit_scale = min(V.width / I.width, V.height / I.height)
scale = fit_scale * z
letterbox = (V.size - I * fit_scale) / 2
origin = V.position + letterbox + p
T = Transform2D((scale, 0), (0, scale), origin)
viewport_point = T * image_point
image_point = T.affine_inverse() * viewport_point
```

Drawing, Render hit-testing, Edit hit-testing, resize handles, and pointer coordinates all use this shared transform. Zoom is anchored at the mouse or viewport center. On resize, the image coordinate previously under the old viewport center is moved under the new center; `Fit` restores `z = 1` and `p = (0, 0)`.

Clicks in letterbox or outside-image space clear selection without entering Edit. A drag must begin inside the displayed image; subsequent motion and release are clamped to `[0, image_width] × [0, image_height]`. Transform tests cover horizontal and vertical aspect ratios, non-zero viewport origins, 0.1×/1×/20× zoom, pan, Fit, and resize. Round-trip error is checked in image coordinates against `1e-5`.

## Geometry and overlay contract

- A valid `polygon` is canonical when a region also has a `box`; the box is only a fallback. Render, selection, preview movement, and committed movement use the same `RegionGeometry` helper.
- Model Output V1 represents a single-ring, non-self-intersecting polygon. Convex and concave polygons are supported; holes, multipolygons, curves, and a schema-v2 geometry extension are intentionally out of scope.
- The deterministic sample still contains approximately 20 regions per frame and now includes one 12-vertex concave complex polygon in every frame.
- `Overlay opacity` changes only the class-color fill alpha. Outlines, labels, confidence text, label backgrounds, and handles remain legible. A selected region uses a fully opaque fill and wider outline.
- Schema-valid model records do not contain `filled`; therefore a missing `filled` value defaults to a visible fill. The existing corrected-record-only `filled: false` state can still hide an unselected fill without changing Model Output V1.
- Labels use a dark contrast background and are clamped to the viewport rectangle.

## Rendering strategy

The implementation keeps the Render plugin and Plugin API version 1 unchanged. It deliberately stays on `CanvasItem` instead of introducing an early shader or RenderingServer mesh path.

- Godot retains `_draw()` commands, and the viewport uses dirty redraw via `queue_redraw()` only after texture, record, selection, opacity, or transform changes.
- The Renderer snapshots and parses image-space geometry, class colors, labels, and bounds only when record content changes. Zoom, pan, selection, and opacity rebuild screen-space commands without reparsing the source dictionary.
- Transformed AABBs cull regions fully outside the viewport.
- `AnnotationViewport` remains the deep-copy boundary. Edit drag previews no longer make redundant copies before passing state to that boundary, and the Renderer never owns or mutates Store data.
- Polygon pre-triangulation, texture atlases, shaders, and low-level mesh batching were not added because the measured path already exceeds the Assignment threshold. They should be reconsidered only if profiling a larger/high-vertex workload identifies polygon triangulation as the bottleneck.

## Reproducible performance measurement

Command, from the repository root:

```bash
"$GODOT_BIN" --path . --script tests/benchmarks/godot/display_benchmark.gd -- \
  --output /tmp/part2_1_display.json --warmup 2 --duration 10
```

The visible-window benchmark uses 1280×800, the first canonical sample frame, 20 mixed box/polygon regions, two seconds of animated warm-up, then ten seconds split across pan, zoom, and an actual `basic_edit_tools` region drag. It records every process-frame interval, commits the drag through `CommandHistory`, and checks selection and image-coordinate displacement. The raw reference-host record is in `tests/benchmarks/results/part2_1_display.json`.

| Field | Measured value |
|---|---:|
| UTC timestamp | 2026-09-04T10:17:36 |
| Host CPU | AMD Ryzen 9 7945HX with Radeon Graphics |
| Godot | 4.7.2-stable (official) |
| Display / renderer | X11 / GL Compatibility / OpenGL 3 |
| Reported adapter | llvmpipe (LLVM 15.0.7, 256 bits) |
| Viewport / regions | 1280×800 / 20 |
| Warm-up / measured duration | 2.0 s / 10.0 s |
| Measured frames | 1753 |
| Mean frame time | 5.705 ms |
| Mean frame rate | 175.27 fps |
| p95 frame interval | 9.572 ms |
| Drag coordinate error | 0.0 image px |
| Drag history / selection | 1 undo item / `sample-r01` |
| Result | PASS |

Acceptance requires mean `≥30 fps`, p95 `≤40 ms`, coordinate error `≤1e-5` image px, the expected selection, and exactly one committed drag. All conditions passed. The X11 session reported `llvmpipe`, so this is explicitly a software-rendered result for this host, not a generalized performance promise for every laptop.

A post-run 1280×800 framebuffer capture was also inspected: the original frame retained its aspect ratio with horizontal letterbox bands, all 20 overlays and contrast-backed labels were visible, the selected region remained emphasized, and the 12-vertex concave region rendered with its notches intact. This temporary diagnostic capture is not a separate report or required deliverable.

## Automated evidence and limits

Godot tests cover transform inversion, resize-center preservation, letterbox input exclusion, clamped drags, Fit, polygon-first behavior, concave-notch hit-testing, draw order, class/fallback colors, confidence labels, fill-only opacity, label bounds, geometry-cache reuse, and off-screen culling. Python tests verify that the regenerated 120-frame sample has exactly one 12-or-more-vertex concave polygon per frame and still validates with zero Model Output V1 errors.

Nothing in this Part 2.1 result expands Model Output V1 or claims holes, multipolygons, mask export, polygon vertex editing, or GPU acceleration. Part 2.2 is under a separate, blocked rebuild and does not change this measured result.

## Part 2.2 Editing status

Part 2.2 remains `BLOCKED` only on the visible performance and manual-review gates. The running toolbar now contains seven implemented tools: Add Box, Subtract, Lasso, Fill, Paint, Eraser and Select. Close Gaps, Region Growing and Live Wire were removed by the approved product decisions. Direct deletion of one selected object remains a Select-only `Delete`/`Backspace` action; unselected Subtract may also delete objects fully consumed by its batch contour.

Part 2.2 Editing and Part 2.3 Design note now follow the approved seven-tool interaction contract.
The real viewport, keyboard, undo/redo and V1-refusal gates pass. The current implementation is not accepted as PASS until the visible performance and manual reviewer gates below have run.

| Assignment behavior | Required validation before PASS | Release-gate evidence |
|---|---|---|
| Select, move, resize, 1/5/10 px nudge | Select through the real viewport and command path | Focused integration and keyboard gates pass |
| Relabel list + free text | Both Inspector input routes use validated commands | Focused Inspector and integration gates pass |
| Add and remove | Add Box/Lasso and Select-only deletion | Command and keyboard gates pass |
| Undo/redo for every committed edit | One successful gesture is one reversible command | Command/history gates pass |
| Fill and approximately closed shapes | Ordinary Fill extracts the clicked enclosed blank; Paint WorkingMask Fill accumulates each clicked hole and requests one class only after the whole mask becomes one solid V1 polygon | Advanced-tool, keyboard and real UI gates pass |
| Paint/Eraser live result | Paint repairs/creates simple objects and hands hollow closed outlines to Fill; Eraser subtracts from selection; both preview the result mask with no trajectory or centre dot | Advanced-tool, WorkingMask, renderer-suppression and integration gates pass |
| Batch Subtract and selection cancel | With no selection one contour atomically clips/deletes every intersected region in one history item; repeated/self-crossing paths apply every enclosed lobe; right click clears selection and returns to Select without a command | Advanced-tool and mounted real-UI gates pass |
| Contour closure | Lasso and Subtract auto-snap releases within 12 viewport px; `Space` force-closes and `Enter` does not duplicate closure; viewport pan is middle-button drag only | Advanced-tool, viewport, keyboard and real UI gates pass |
| Keyboard-only reachability | `V/A/S/L/F/P/Shift+P`, spatial input and focus traversal; `C/E/G/I` unbound | Keyboard gate passes |
| Invalid-edit refusal | V1 rejection leaves Store/history unchanged | Command and geometry gates pass |

### V1 geometry, fill and responsiveness gates

Finite, non-self-intersecting V1 geometry and atomic rejection without Store/history mutation pass automated validation. Responsiveness during visible Paint/Eraser editing and the manual reviewer sequence remain pending, so this section does not claim Part 2.2 PASS.

Automated checkpoint on 2026-09-05:

- `tests/run_tests.sh` exited `0`; its component gates reported `PASS: complete Godot test suite`, `PASS: PolygonOps vector geometry`, `PASS: image region algorithms`, `PASS: advanced edit tools`, and `PASS: keyboard-only edit reachability`.
- `tests/run_tests.sh` reported `219 passed` for the Python suite before running the Godot gates.
- `python/validate_model_output.py sample/assignment_v1/model_output_v1.jsonl` reported `Validation errors: 0`.
- `git diff --check` produced no errors.

## Part 2.3 MITK interaction-fidelity decision log

Part 2.3 remains `BLOCKED` until the seven-tool visible-performance and manual-review gates have run. The reference is the official [MITK Segmentation View](https://docs.mitk.org/latest/org_mitk_views_segmentation.html); these decisions do not claim MITK equivalence.

| MITK-style interaction | Target status | Proposed 2D target | Why |
|---|---|---|---|
| Active selection and visible selected state | Implemented | Shared-transform hit-test, opaque selected fill, wider outline and eight bounds handles | Directly preserves the mature-tool principle that the active object must be unambiguous. |
| Application-wide undo/redo | Implemented | Bounded 200-command history; `Ctrl+Z`, `Ctrl+Shift+Z`, and visible Redo button; no visible Undo button by project UI decision | Matches the interaction expectation while satisfying the requested compact toolbar. |
| First-letter tool activation | Implemented | `V/A/S/L/F/P/Shift+P`; `C/E/G/I` are unbound; Tab remains standard focus traversal | Keeps keyboard reachability while reserving Space for Lasso/Subtract closure and arrows for spatial editing. |
| Move, bounds resize and pixel nudge | Implemented | Select manipulates 2D box/single-ring polygon geometry in image coordinates | Video annotations are structured vector regions, not MITK image voxels; one shared transform prevents display/edit drift. |
| Fill | Adapted and implemented | Clicking blank annotation-layer space flood-fills its smallest enclosed connected component, then creates one classified V1 polygon | MITK Fill relabels connected pixels; this client treats existing annotations as boundaries and refuses occupied or exterior-connected seeds. |
| Close Gaps | Dropped | No toolbar descriptor, capability or shortcut; `C` is inert | The user removed this interaction; Fill now reports an annotation boundary that remains genuinely open. |
| Paint and Eraser brushes | Adapted and implemented | Paint repairs/creates a simple object; a hollow closed outline remains an orange WorkingMask for retryable Fill; Eraser subtracts from selection | Preserves correction-brush interaction without writing holes or masks into V1. |
| Region Growing | Dropped | No descriptor, capability or shortcut; `G` is inert | It is not required by the Assignment representative subset and the colour-tolerance result was not dependable enough for this medical-video scope. |
| Live Wire | Dropped | No descriptor, capability or shortcut; `I` is inert | Straight anchor segments duplicated Lasso's point-by-point contour interaction without adding a distinct editing result. |
| Freehand contour add and Subtract | Adapted and implemented | Lasso adds one solid V1 ring; Subtract targets the selection or atomically clips/deletes all intersected regions when unselected; near endpoints auto-snap and multi-enclosure paths use a bounded mask fallback | One gesture remains one undo item; holes or inexpressible remainders are never persisted. |
| polygon vertex editing (add/move/delete individual vertices) | Proposed exclusion | No individual-vertex mode is planned; polygon resize remains bounds-affine | The Assignment marks it optional; direct vertex UX would add substantial state and validation work. |
| 3D volume, multi-slice interpolation and other volumetric workflows | Proposed exclusion | No 3D or slice-stack editing semantics are planned | The assigned client is a 2D video-region workflow; claiming these would be outside the source/data model and would falsely imply MITK equivalence. |

The immutable `model_output_v1` baseline remains a Part 1 contract. Automated Part 2.2 interaction evidence now passes, but the visible-performance and manual reviewer gates remain **待验证**; therefore Part 2.2/2.3 are not yet marked PASS.

## Part 3.1 Frame-accurate stream status

Part 3.1 is `PASS` on the measured host. The client now imports an FFmpeg-readable video in the background, opens the resulting indexed source, provides Play/Pause, Previous, Next and timeline seek, displays an explicit zero-based frame and `HH:MM:SS.mmm` time, and keeps decoded image pixels behind a 12-texture LRU cache. Part 3.2 and Part 3.3 remain incomplete and are not claimed by this result.

Model Output V1, the dataset manifest and Plugin API version 1 did not change for this work. A raw video is an import job, not a codec-level Source plugin. Successful normalization is handed to the existing `image_sequence_source`, so video-derived and native indexed image sequences use the same frame/annotation path.

## Background video-import contract

`VideoImportController` uses `OS.create_process()` to run only the repository's `.venv/bin/python` and never falls back to an unverified system interpreter. The modal UI requires an explicit output parent and a new, non-existing directory name. It pauses playback and cancels transient edit preview before import. The previously opened dataset remains active until the published output passes the normal transactional `open_source()` checks.

The CLI remains backward compatible with the original input plus `--output` invocation and the existing successful `--result-file` object. Optional job-control arguments add:

- `--progress-file`: an atomically replaced JSON object with exactly `version`, `state`, `stage`, `completed`, `total`, `fraction` and `message`;
- `--cancel-file`: a cooperative cancellation request checked during probe, extraction, frame normalization, validation and source hashing;
- `--staging-dir`: a new sibling directory that is the only task-owned directory eligible for cleanup.

Progress is monotonic across `probe`, `extract`, `validate` and `publish`. Probe and extraction children are polled without blocking the Godot UI. On cancellation Python terminates its active FFprobe/FFmpeg child, removes only its owned staging directory, emits a cancelled result and leaves the input, any existing output and the current client dataset untouched. Publication is a final same-parent rename; a pre-existing target is refused before any work begins. Missing project Python, FFmpeg or FFprobe produces a bounded message pointing to the README recovery steps.

The real integration record is `tests/benchmarks/results/part3_1_import.json`. Its input was a reproducible 3-second, 640×360, 30 fps FFV1 MKV with 90 frames.

| Import field | Measured value |
|---|---:|
| UTC timestamp | 2026-09-04T07:33:21 |
| Input size | 615,423 bytes |
| Output size | 1,012,265 bytes |
| Background import plus client open | 0.789 s |
| UI process heartbeats while running | 107 |
| Progress events / observed stages | 30 / probe, extract, validate, publish |
| Opened result | frame 0 of 90 |
| Old dataset preserved until completion | yes |
| Result | PASS |

The input used a lossless codec to make the measurement deterministic; the importer itself remains bounded by what the installed FFmpeg can decode. PNG normalization trades storage size for explicit, independently addressable frames.

## Playback timing and interaction contract

`PlaybackController` is a small state machine; `AnnotationMain` remains the only current-frame and frame-commit owner. The wait after frame `i` is:

```text
interval(i) = time_s[i + 1] - time_s[i]
if interval(i) <= 0: interval(i) = 1 / nominal_fps
```

Each `_process(delta)` call can request at most `current + 1`. Once one frame becomes due, excess elapsed time is discarded instead of being retained for catch-up. Consequently a slow load or slow renderer reduces wall-clock playback speed but never skips an explicit index. `set_frame()` loads the texture, corrected annotation and frame entry before committing any state. A failure pauses and preserves the last successfully displayed texture, annotation, selection and dataset.

- Play cancels transient edit preview and starts after the current frame.
- Pause stops immediately on the current committed frame.
- Previous and Next pause, then move exactly one bounded index.
- Timeline and Explorer seek pause, then request the exact chosen index.
- The final frame pauses automatically; Play is disabled there and playback never loops.
- Playback keeps visible controls instead of claiming editing keys; Space force-closes Lasso/Subtract, near mouse releases auto-snap, arrow keys remain available for editing, and viewport pan uses middle-button drag only.

The visible raw record is `tests/benchmarks/results/part3_1_playback.json`. It used the 640×360 canonical imagery expanded to 360 indexed frames, with 20 mixed box/polygon regions per frame. The 12-cache entries were warmed before the timed run so the record contains both hits and misses.

| Playback field | Measured value |
|---|---:|
| UTC timestamp | 2026-09-04T06:57:57 |
| Host CPU | AMD Ryzen 9 7945HX with Radeon Graphics |
| Display / adapter | X11 / llvmpipe (LLVM 15.0.7, 256 bits) |
| Source / regions | 640×360 / 20 |
| Measured duration / UI heartbeats | 10.011 s / 823 |
| Delivered indices | 1 through 256, all consecutive |
| Skipped frames | 0 |
| Actual playback rate | 25.57 fps |
| Mean / p95 delivery interval | 39.107 / 44.616 ms |
| Mean / p95 synchronous frame load | 3.856 / 5.194 ms |
| Cache hits / misses | 11 / 245 |
| Final cache size / limit | 12 / 12 |
| Client open time | 475.285 ms |
| Result | PASS |

The measured software-rendered host did not sustain the 30 fps nominal clock: actual delivery was 25.57 fps and p95 delivery interval was 44.616 ms. This is the expected result of the approved no-skip policy, not a hidden frame drop. Part 2.1's separate rendering threshold still passes at 175.27 fps; Part 3.1 itself requires frame-accurate controls, exact alignment and bounded loading, not a codec-player real-time guarantee. A future optimization may decode CPU image data off the main thread, but the first version intentionally does not create `ImageTexture` resources from a worker thread.

## Long-clip boundedness

Manifest entries and annotation metadata may reside in memory, but image pixels are loaded on demand. `FrameCache` retains at most 12 textures. Timeline draws only visible cells and creates no per-frame Button. `DatasetExplorer` lists individual frames only through 500 entries; above that limit it materializes a dataset summary, exact total, one current-frame item and real artifacts. Timeline and transport remain the exact navigation mechanisms.

The raw 10,000-frame stress record is `tests/benchmarks/results/part3_1_long_source.json`.

| Long-source field | Measured value |
|---|---:|
| UTC timestamp | 2026-09-04T06:58:06 |
| Client open time | 1,048.448 ms |
| Exact seek targets | 0, 5000, 9999, 137, 8765 |
| Mean / p95 seek | 1.652 / 2.691 ms |
| Explorer TreeItems / frame items | 5 / 1 |
| Timeline per-frame Buttons | 0 |
| Texture cache size / limit | 5 / 12 |
| Static memory before / after open and seeks | 26,945,209 / 113,992,419 bytes |
| Result | PASS |

The memory increase includes 10,000 manifest dictionaries, 10,000 synthesized empty annotation records and Godot UI/runtime state; it is not 10,000 decoded 640×360 textures. This design deliberately bounds pixel memory while allowing searchable frame metadata to remain resident.

## Part 3.1 automated evidence and limits

Python tests cover CFR/VFR-relevant timestamp handling, rotation, negative and wholly missing PTS, multiple streams, progress shape and monotonicity, explicit staging, target collisions, missing tools, cancellation and active child termination. Godot tests cover the playback state machine, duplicate-timestamp fallback, no catch-up skipping, controls, last-frame stop, failed-load preservation, modal routing, non-blocking process heartbeat, cooperative cancellation and 10,000-frame Explorer materialization. Reproducible benchmark tools and their raw results live together under `tests/benchmarks/`.

Audio playback, codec-level seeking, background `ImageTexture` creation, prefetching, looping and all Part 3.2 batch-labelling semantics are out of scope. In particular, the existing similarity scores and range-propagation primitive do not constitute the required Part 3.2 keyframe/verification workflow, so Part 3.2 and its Part 3.3 measurement remain `BLOCKED`.
