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

Nothing in this Part 2.1 result expands Model Output V1 or claims holes, multipolygons, mask export, polygon vertex editing, or GPU acceleration. Part 2.2 has separate editing measurements below and does not change this stored display baseline.

## Part 2.2 Editing status

Assignment 2.2 implementation, automated interaction checks and visible performance checks are complete on the measured host. The project-level Part 2.2/2.3 release status remains `BLOCKED` only on the human reviewer run on the canonical sample and a paused surgical-video frame. Automated visible execution is not recorded as human acceptance.

The seven tools are Add Box, Subtract, Lasso, Fill, Paint, Eraser and Select. Selection, dragging, bounds handles, 1/5/10 image-pixel nudging, list/free-text reclassification, creation and deletion use validated commands. The optional saved-polygon vertex editing is now available within Lasso.

| Assignment behavior | Implementation and direct evidence |
|---|---|
| Select, move, resize, nudge | Shared transform; topmost interior hit, then a 6 viewport-px edge fallback; nearest handle within 8 viewport px. Existing command/keyboard suites plus overlapping-handle regression. |
| Relabel list + free text | Current Main uses the annotation tree and ClassAssignmentDialog; Enter activates a row, suggestions and editable class/kind fields use the same validated command. Mounted Main and dialog tests. |
| Saved-polygon vertices | Select a polygon and activate Lasso. Drag vertices, double-click edges to insert, Delete/Backspace to remove; brackets select vertices, arrows nudge by 1/5/10 image px, Insert bisects the next edge. Validated geometry commands preserve metadata and support undo/redo. |
| Add and remove | Keyboard/mouse box and Lasso creation; Select Delete/Backspace; atomic unselected Subtract. Existing advanced and keyboard suites. |
| Undo/redo | 200 committed commands. Failed apply/revert retains both stacks; batch restoration validates all frames before mutation. Real Store refusal and observer/provenance regressions in `test_checked_history.gd`. |
| Approximately closed Fill | Strict fill first, then square-kernel morphological closing with radius 0/1/2/3 image px, default 1. Only repair components adjacent to the chosen blank survive. Green candidate and pink repair pixels require Enter/Apply fill; Escape/Cancel restores the prior contour. |
| WorkingMask continuation | F enters a seed cursor; arrows and Enter continue filling the same frozen contour. Two-hole Fill, local undo/redo, final one-command commit and cancellation are tested. |
| Keyboard reachability | Tab/Shift+Tab leave active spatial tools without discarding the draft. Text focus owns text undo, an active contour owns draft undo, otherwise Main owns committed undo. Real Main input/focus and repair buttons are tested. |
| Invalid-edit refusal | Bounds, non-finite coordinates, degenerate/self-intersecting geometry, holes, multiple components and mask budget violations produce explanatory errors. Oversized or subpixel-empty Paint targets cannot silently turn into new regions. |

### Algorithm changes and limits

`BrushStrokeBuffer` visits only the newly appended capsule, stores a geometrically growing local mask and returns owned snapshots. Region masks are rasterized lazily after a bounds overlap check. Raw polygon rasterization skips contour extraction; union/subtract use row copies and limited changed-area scans. `EditOverlay` uses two-byte luminance/alpha images and reuses compatible textures. Contour extraction and validated command creation occur on release, not on every motion event.

The measured 128-point brush fixture took 4.663 ms for all appends and 4.071 ms for all snapshots, compared with 532.850 ms for one final legacy rasterization. A separate 1280×800 mask plus 32×32 stroke fixture measured union 349.530→0.259 ms and subtraction 346.989→0.087 ms. These are headless microbenchmarks with different work counts, not FPS claims; the visible complete-preview measurement below is authoritative for responsiveness. Reproduction notes remain in `tests/output/brush-buffer-report.md` and `tests/output/mask-preview-report.md`.

Every raster ROI remains capped at 1,048,576 pixels, including padding. Oversized annotation-boundary unions are explicitly refused. Artificial ROI boundaries are padded; exterior-connected seeds and real image edges are never treated as closed annotation boundaries. Closing is a proposed repair, not image-content inference. A radius is the square kernel's reach; a particular gap is not guaranteed to close. Filled masks must still become one legal V1 ring. Boundary simplification uses at most 0.5 image-px deviation with topology validation; contours above 256 vertices retain their exact collinear-reduced boundary. Existing 16,384 boundary-edge and 2,048 output-vertex limits remain.

WorkingMask history records changed mask bytes and ROI transitions, bounded to 200 entries / 32 MiB of diff storage. It does not mutate Store. A repaired candidate is not a history entry until accepted; accepting the final Fill and class produces one committed region command. Ctrl+Z on a repair preview cancels that preview first. New draft edits clear draft redo.

### Lasso vertex editing — 2026-09-06

Click-based Lasso creation now exposes the actual clicked points while drawing: p1, p2, p3 and subsequent points remain individually draggable. Space or double-click closes the contour; class confirmation immediately keeps those same saved vertices editable. Explicit clicked coordinates and ordering, including collinear control points, are preserved without simplification or raster reconstruction. Freehand stroke processing retains its separate simplification path. Idle vertex mode displays the class fill and label, hides bounding-box handles and overlays only the actual contour controls.

`polygon_vertex_editor.gd` owns vertex selection, screen-space handle/edge picking and frozen drag previews. Picking uses an 8 viewport-pixel tolerance and nearest point/segment searches; edge insertion projects onto the edge. Geometry remains in image coordinates. Release-time simple-polygon validation rejects duplicate vertices, crossings, zero area and more than 2,048 vertices; at least three vertices must remain. Keyboard edits outside the image are refused, while pointer drags follow the existing viewport boundary clamp. A changed frame, selection or Store snapshot refuses a stale drag. Each accepted operation uses `ReplaceRegionGeometryCommand`, preserving region metadata and global undo/redo. No existing polygon is rasterized or simplified for vertex editing.

`test_polygon_vertex_editing.gd` covers mouse and keyboard changes, 1/5/10 px steps, insertion, deletion, cancellation, minimum vertex count, invalid topology, stale snapshots, full-record undo/redo and mounted Main input. Idle handles remain available after empty undo/redo. The existing FPS figures below measure Select/brush/zoom scenarios; they are not a separate vertex-editing performance benchmark. The final full runner exited 0 with 221 Python tests, the complete Godot suite and all nine standalone gates passing. The vertex suite also passed in an independent X11 window. A real click-create-drag test used a six-point concave contour, moved the inward third point before and after class confirmation, and verified that only that point changed; the captured viewport shows contour controls and the filled polygon without bounding-box handles.

### Visible editing performance — 2026-09-06

```bash
source project_env.sh
"$GODOT_BIN" --path . --script tests/benchmarks/godot/editing_benchmark.gd -- \
  --output tests/benchmarks/results/part2_2_editing.json --screenshot /tmp/project6-editing.png
```

The independent X11 window was 1280×800, using the canonical 640×360 first frame and 20 mixed regions. The edited target was enlarged to 320×150 image px to exercise larger result-mask previews. Each scenario received 2 s warmup and 10 s measurement, with an 8 image-px brush. Godot 4.7.2 GL Compatibility used `llvmpipe (LLVM 15.0.7, 256 bits)`. Thresholds were mean ≥30 fps and p95 frame interval ≤40 ms.

| Scenario | Frames | Mean fps | p95 frame ms | Release/commit ms | Result |
|---|---:|---:|---:|---:|---|
| Select drag | 1869 | 186.86 | 8.181 | 1.087 | PASS |
| Paint | 1745 | 174.49 | 8.775 | 82.052 | PASS |
| Eraser | 1802 | 180.16 | 8.643 | 91.566 | PASS |
| Zoom/pan | 2342 | 234.12 | 6.848 | n/a | PASS |

Frame intervals cover live preview and rendering. Release, contour conversion, validation and the command are measured separately; the 82–92 ms brush commits are not included in the live-preview FPS. Each editing scenario additionally required exactly one successful command. The unrestricted Eraser follows the enlarged target’s top edge (x=85..220, y=82±6 image px) and processes every touched region. A separate multi-target test covers complete deletion, empty-space strokes and atomic refusal when one result would split a region. The raw samples, configuration and screenshot paths are in `tests/benchmarks/results/part2_2_editing.json`. Paint/Eraser screenshots were inspected. These figures describe this host and fixture, not all image sizes, drivers or video workloads.

### Automated verification

The final verification command is `XDG_DATA_HOME=/tmp/project6-edit-verify XDG_CONFIG_HOME=/tmp/project6-edit-config tests/run_tests.sh`. The runner includes the existing Python/Godot gates and four new standalone gates: brush buffer, bounded Fill solver, checked history, and Assignment editing regressions. The latter mounts real Main, tests text-versus-draft undo and repair buttons, and exports repaired geometry through the actual Feedback plugin. Its exported JSONL is also checked by the independent Python validator. Original-model digest and file-byte invariance remain covered.

The 2026-09-06 final run exited 0: **221 Python tests passed**, the complete Godot suite and all eight standalone Godot gates passed. Both the canonical model JSONL and the repaired corrected export reported `Validation errors: 0`. Additional solver checks confirmed unrelated outlines are not repaired and safety padding counts toward the mask budget. The visible mounted-Main regression also passed; its screenshot showed annotation boundaries, the green fill candidate, pink gap repair and both confirmation buttons. The canonical model SHA-256 remained `87bf665f80aacd97c44a2122a178e9522e63df076192cabb16758758965851bf` before and after verification. `git diff --check` was clean. Expected corrupt-image recovery fixtures and the headless editor's unavailable debug-listen socket did not fail the suite.

The independent code review identified two edge cases: empty subpixel raster targets and Tab consumed during keyboard Fill. Both were reproduced by failing regressions, fixed, and rerun successfully. A subsequent review caught R interrupting a just-pressed Selection drag; gesture-state routing now protects both move and resize before their first motion. Mounted-Main tests verify R relabel with free text; dialog tests verify the full initial class list. No human reviewer sign-off is implied by that code review.

## Part 2.3 MITK interaction-fidelity decision log

### Reference and design scope

This note answers Assignment 2.3 for the current client. The reference is MITK's official [Segmentation View](https://docs.mitk.org/latest/org_mitk_views_segmentation.html), particularly selection, label naming, manual 2D tools and undo/redo; the [ContourTool implementation documentation](https://docs.mitk.org/latest/classmitk_1_1ContourTool.html) also describes visible contour feedback followed by a release-time write. These references were checked on 2026-09-06. The comparison is based on documentation and our client's tested behavior; it does not claim a side-by-side usability study in MITK Workbench.

Our editing unit is an identified box or single-ring polygon on one video frame. The design therefore preserves visible targets, direct manipulation, reversible edits and explicit feedback, while adapting operations to Model Output V1. The seven shipped tools are Add Box, Subtract, Lasso, Fill, Paint, Eraser and Select.

### Interactions emulated and adapted

| Interaction / reference behavior | Decision | Current client behavior and reason |
|---|---|---|
| MITK selection and label highlighting | Emulated, with 2D picking adaptations | Clicking selects the topmost region under the shared image/viewport transform; the selected state and sidebar identify the target. Sidebar hover highlights the corresponding region. A 6 viewport-px edge tolerance assists small targets, and the nearest resize handle is picked within 8 viewport px. These tolerances remain usable after zooming. |
| Manual contour feedback and completion | Emulated at the interaction level | Lasso/Subtract show an editable path; Paint/Eraser show the resulting masks while drawing. Completed geometry is validated before a command changes annotations. New objects additionally require class confirmation. This keeps unfinished work visible and cancellable. |
| Saved-polygon vertex correction | Added for explicit object geometry | Lasso also edits individual vertices of an already saved polygon, with visible active-point feedback, edge insertion and vertex deletion. Mouse and keyboard use the same validated geometry command. This supplements contour drawing without claiming MITK has identical object-vertex controls. |
| Region manipulation required by the Assignment | Added for object annotations | Select supports dragging and eight bounding handles for box/polygon resize. Arrow keys move by 1 image px, Shift by 5, and Ctrl+Shift by 10; Alt+Arrow resizes. These are object-space operations for correcting model boxes/polygons, rather than a claim that MITK's segmentation Selection tool provides identical handles. |
| MITK label naming and suggestions | Adapted | Double-clicking a right-sidebar annotation opens the class dialog; list Enter or canvas R provides keyboard access. The dialog initially shows all suggestions and permits free-text Class and Kind. Wheel navigation changes the selected suggestion, updates both fields and previews its color; Confirm saves, Cancel discards. Double-clicking a suggestion also confirms. MITK's ordinary label double-click selects/centers; our direct rename entry and wheel navigation are deliberate shortcuts for repeated corrections. |
| Add/Subtract and brush correction | Adapted | Add Box creates a rectangular object; Lasso creates a polygon. Paint unions with the unique overlapping or explicitly selected target; an independent stroke can create an object. Subtract affects a selected object, or all intersecting objects when unselected. Eraser always affects every region touched by its stroke, regardless of selection, and may delete fully erased objects. A multi-object stroke is one atomic undoable command. This removes repeated target-selection steps during cleanup. |
| MITK Fill and Close | Adapted, with different geometry semantics | Our Fill operates on blank areas bounded by annotations or a temporary Paint mask. It first attempts strict enclosure, then optionally proposes small-gap repair with a 0–3 image-px closing radius. The filled candidate is green and proposed repairs are pink; Enter/Apply fill accepts, Escape/Cancel restores the previous draft. Hollow Paint contours retain the same WorkingMask while successive holes are filled. This implements the Assignment's approximate closure without treating RGB intensity as a segmentation boundary or equating our Fill with MITK's connected-label replacement. |
| Undo/redo | Emulated and extended to draft ownership | Up to 200 committed commands cover creation, movement, resize, relabel, filling, subtraction and deletion. WorkingMask edits have a separate history capped at 200 entries and 32 MiB; focused text fields retain their own text undo. A failed edit leaves annotation data and history unchanged. This gives each undo action a predictable scope. |
| Tool shortcuts and interaction ownership | Adapted | All implemented edits have keyboard paths documented in README. Space closes keyboard contours; Enter completes brush strokes or confirms dialogs; Escape cancels. Editing pauses playback and operates on a fixed frame. Class dialogs own their input, and R cannot interrupt an active drag. Explicit tools replace modifier-based inversion, leaving Ctrl combinations available for history and precise nudging. |

### Interactions omitted and trade-offs

- **Region Growing and Live Wire:** not exposed in the current client. The representative subset focuses on manual correction of existing model regions; intensity thresholds and edge-following would need separate evaluation on surgical RGB frames with changing illumination and weak boundaries.
- **Close Gaps as a separate tool:** omitted from the toolbar. Approximate closure is an explicit Fill option with an acceptance preview, keeping its effect visible without another editing mode.
- **3D volumes, orthogonal-slice editing and slice interpolation:** outside this frame-based region editor. Video frames are treated as temporal observations; slice interpolation is not used as automatic propagation between them.
- **MITK group/label locking semantics:** not reproduced. Regions retain independent IDs and can overlap. Schema validation, atomic commands and undo protect edits, but there is no equivalent lock preventing Eraser from touching a region. Users should inspect the batch preview before completing a stroke.
- **Holes, multipolygons and persistent raster-mask geometry:** outside Model Output V1. Working masks are temporary editing data; committed regions must remain valid boxes or simple single-ring polygons. An inexpressible result is refused with an explanation, and one invalid target rejects an entire multi-object edit. This favors explicit refusal over silently changing the exported representation.

### Evidence and reviewer procedure

The runnable client opens the canonical synthetic sample through the README runbook. The [README shortcut table and reviewer script](README.md#part-2223-实现状态与验收门禁) cover each editing feature on that sample and a paused surgical-video frame. Current automated evidence includes:

- `test_edit_integration.gd` and `test_keyboard_reachability.gd`: real client input, selection, drag/resize, 1/5/10 px steps, creation, relabel and keyboard editing paths.
- `test_class_assignment_dialog.gd`: list/free-text input, real wheel events, field/color synchronization, long-list navigation, explicit confirmation and cancellation. The same dialog suite passed in a visible X11 window.
- `test_advanced_edit_tools.gd`, `test_fill_region_solver.gd`, `test_checked_history.gd` and `test_editing_assignment.gd`: multi-region erasure, complete deletion, all-or-nothing refusal, cumulative Fill, gap acceptance/cancellation, checked history and modal/gesture ownership.

The latest complete Godot suite and 12 documentation tests passed after wheel selection was added. Performance measurements are recorded separately in Part 2.1/2.2: with 20 regions at 1280×800, the current benchmark measured 186.86 fps for dragging and 234.12 fps for zoom/pan on Ryzen 9 7945HX with llvmpipe software rendering. This is responsiveness evidence for that host, not a measurement of human labeling speed or a test on an ordinary-configured laptop.

The Part 2.3 design note is complete. Human reviewer results on the canonical sample and paused surgical video have not been recorded; the combined Part 2.2/2.3 release rows therefore remain **待验证 / BLOCKED**. Automated interaction tests do not substitute for that human acceptance record.

## Part 3.1 Frame-accurate stream status

Part 3.1 is `PASS` on the measured host. The client imports an FFmpeg-readable video in the background, opens the resulting indexed source, provides Play/Pause, Previous, Next and timeline seek, displays explicit frame/time plus read-only actual FPS, and keeps decoded image pixels behind a 12-texture LRU cache. The displayed `Time HH:MM:SS.mmm` is derived from the committed frame entry's immutable `time_s`, not elapsed wall-clock playback time. This section covers Part 3.1 only; the Part 3.2/3.3 workflow evidence is recorded below.

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

`PlaybackController` is a small state machine; `AnnotationMain` remains the only current-frame and frame-commit owner. The top-toolbar product flow uses explicit seconds-per-frame review timing plus an unrestricted mode:

```text
Custom interval = user seconds_per_frame, bounded to [0.01, 60]
fixed intervals = 3 s/frame or 1 s/frame
Max interval = 0 artificial seconds; request one next index per process tick
```

All multi-frame sources default to `1 s/frame`. The top toolbar normally contains only a current-status button; clicking it opens the `Custom | 3 s | 1 s | Max` adjustment popup, and clicking outside closes it. Selecting Custom reveals a 0.01–60 s/frame numeric input inside that popup. The transport presents explicit frame/time from the committed Source entry and a separate read-only actual FPS. `PlaybackFpsMeter` receives only monotonic timestamps after `set_frame()` has successfully committed image, annotation and time alignment. Speed selection, source-time display and FPS display change only presentation: original `frame_id`, `time_s`, sample identity, Store records, dirty state and label JSON remain unchanged. Label files are parsed once when media opens and corrected records stay in memory, so playback does not re-read JSON on every frame.

Each `_process(delta)` call can request at most `current + 1`. Timed modes discard excess elapsed time instead of retaining it for catch-up; Max removes that wait but preserves the same one-index-per-tick rule. Consequently a slow load or slow renderer reduces wall-clock playback speed but never skips an explicit index. `set_frame()` loads the texture, corrected annotation and frame entry before committing any state. A failure pauses and preserves the last successfully displayed texture, annotation, selection and dataset. Changing speed also pauses first, preventing partial elapsed time from leaking between modes.

- Play cancels transient edit preview and starts after the current frame.
- Pause stops immediately on the current committed frame.
- Previous and Next pause, then move exactly one bounded index.
- Timeline and Explorer seek pause, then request the exact chosen index.
- The final frame pauses automatically; Play is disabled there and playback never loops.
- Sparse workspace IDs such as 16 and 23 remain adjacent playback items: they wait one second by default, three seconds in the slow preset, an exact Custom interval, or only the next process tick in Max.
- Playback keeps visible controls instead of claiming editing keys; Space force-closes Lasso/Subtract, near mouse releases auto-snap, arrow keys remain available for editing, and viewport pan uses middle-button drag only.

The visible raw record is `tests/benchmarks/results/part3_1_playback.json`. It used the 640×360 canonical imagery expanded to 360 indexed frames, with 20 mixed box/polygon regions per frame. The 12-cache entries were warmed before the timed run so the record contains both hits and misses. This stored baseline uses the controller's exact 30 fps review clock directly, records that request in the raw JSON, and deliberately bypasses the Custom UI input so its 0.01-second display step cannot alter the performance baseline. The product default remains 1 s/frame.

| Playback field | Measured value |
|---|---:|
| UTC timestamp | 2026-09-05T20:07:04 |
| Host CPU | AMD Ryzen 9 7945HX with Radeon Graphics |
| Display / adapter | X11 / llvmpipe (LLVM 15.0.7, 256 bits) |
| Source / regions | 640×360 / 20 |
| Measured duration / UI heartbeats | 10.026 s / 153 |
| Delivered indices | 1 through 153, all consecutive |
| Skipped frames | 0 |
| Actual playback rate | 15.26 fps |
| Mean / p95 delivery interval | 65.531 / 74.116 ms |
| Mean / p95 synchronous frame load | 8.639 / 11.902 ms |
| Cache hits / misses | 11 / 142 |
| Final cache size / limit | 12 / 12 |
| Client open time | 581.526 ms |
| Result | PASS |

The measured software-rendered host did not sustain the exact 30 fps requested clock: actual delivery was 15.26 fps and p95 delivery interval was 74.116 ms. This is the expected result of the approved no-skip policy, not a hidden frame drop. Part 2.1's separate rendering threshold still passes at 175.27 fps; Part 3.1 itself requires frame-accurate controls, exact alignment and bounded loading, not a codec-player real-time guarantee. A future optimization may decode CPU image data off the main thread, but the first version intentionally does not create `ImageTexture` resources from a worker thread.

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

Audio playback, codec-level seeking, background `ImageTexture` creation, prefetching and looping remain outside the Part 3.1 implementation. The batch workflow is described in the following section.

## Single-frame Model Assist (2026-09-10)

Model assistance is now the ninth single-frame edit tool, after Match in the eighth slot; it is not a Batch algorithm. With no selection it creates a pending Model Output V1 Poly for classification. With a selected Box or Poly it replaces only that region's geometry and preserves its ID, class and attributes. The first positive/negative point or prompt box freezes the original frame ID, contiguous playback index, image digest, record digest and optional target identity. Candidate application rechecks all frozen identities and enters command history as one atomic create or replace operation.

`ModelAssistSession` owns prompt and candidate state. `ModelAssistService` owns asynchronous preflight, one external process, the bounded `model-assist-v1` JSONL exchange, deadlines, cancel/stale behavior and job cleanup; it has no Store write authority. Returned masks must be non-linked binary PNGs below the owned job directory with matching SHA-256, dimensions and ROI. Godot then requires one hole-free connected component, a simple V1 ring, no more than 2,048 vertices and raster round-trip IoU of at least 0.99 before exposing Apply. A terminal worker crash, malformed response or timeout transitions the matching request to a prompt-preserving Failed state with Retry/Cancel rather than leaving navigation blocked. A deterministic fake worker has exercised create, correction, candidate switching, retry, cancellation, stale-result refusal, atomic undo/redo, navigation blocking, save/reopen and shutdown behavior through the mounted Main UI.

The tracked smoke driver separately verifies a user-provided official SAM 2 installation with `hello -> set_image -> predict -> shutdown` and emits an auditable report without overwriting an existing output directory. It uses only explicit `PROJECT6_MODEL_PYTHON`, `PROJECT6_SAM2_CONFIG`, `PROJECT6_SAM2_CHECKPOINT` and `PROJECT6_SAM2_DEVICE` inputs; the client never installs packages or downloads weights.

On this host, **real SAM smoke: PASS** on both CPU and CUDA. The runs used the Conda `project6` interpreter, Meta's official SAM 2 repository at commit `2b90b9f5ceec907a1c18123530e92e794ad901a4`, official SAM 2.1 Tiny checkpoint SHA-256 `7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69`, and local surgical frame `Dataset_test/cholect50-challenge-val/videos/VID68/000016.png` (774×434). The historical CPU run completed in 9.665959 s and returned three binary, hash-checked candidates. The 2026-09-11 CUDA run used Python 3.10.0, Torch 2.11.0+cu128 and an NVIDIA GeForce RTX 5070 Ti Laptop GPU; model load took 2.416052 s, image embedding 0.324668 s and prediction 0.191926 s. It also returned three gated candidates and exited 0. The auditable reports remain local at `.local-acceptance/model-assist-real-20260910-cpu/report.json` and `.local-acceptance/model-assist-user-check-003/report.json`.

The CUDA smoke proves official single-frame SAM inference through the production worker protocol on the named GPU. It is not a SAM Video per-frame latency benchmark. Godot can load the configured runtime, but the complete **visible real-model UI checklist remains not formally recorded**. Neither smoke replaces human checks of create/correct/cancel/persistence behavior or establishes segmentation accuracy. Fake-worker PASS remains implementation evidence only. The exact provisioning, smoke and manual UI procedure is in `docs/model-assist-acceptance.md`.

The earlier merged `tests/run_tests.sh` run passed **524 Python tests in 42.89 s** and all 24 then-registered, log-audited Godot invocations with status 0. It remains historical single-frame Model Assist evidence and is superseded for current aggregate counts by the Task 7 run below. The aggregate emitted exactly the four intentional corrupt-PNG fixture pairs and ended with `PASS: complete Godot test suite`. The restricted-host editor probe emitted exactly two known local debug-listen socket failure pairs; its editor-only profile rejects missing, changed, extra or differently scoped errors. All other Godot profiles remained zero-error. The captured historical merged-run log is `/tmp/project6-merged-full-tests-v7.log`.

## SAM 2 Video Batch default (2026-09-11)

The current implementation makes SAM 2 Video the Batch default and supersedes the former “Batch does not use SAM / Poly is default” decision. Single-frame Model Assist remains a separate Edit tool. `polygon_flow` / `poly-sim-flow-edge-v1` and fixed `copy` remain available only when explicitly selected; a SAM error never silently invokes either alternative.

The default Batch path accepts exactly one committed Box/Poly region and an explicit anchor attestation, then follows Source order forward for 1–30 target entries. The keyframe is excluded. `SamVideoService` freezes the key plus targets, drives the official SAM 2 Video predictor through the bounded `sam-video-v1` JSONL protocol, and returns read-only transient candidates. Preview, cancellation, worker/model failure and stale results cannot change Store, history, review state, labels or training packages.

A topology failure stops at the first inexpressible target and retains only the legal prefix. After confirming that prefix, the user can correct the stop frame with single-frame Model Assist, commit it, explicitly attest the new anchor and start a separate Batch. Protocol, path/hash, process or Source/Store/review/session inconsistency invalidates the entire plan rather than crossing the failure or falling back.

Confirmation is region-scoped and atomic: one `ApplyPropagationCommand` updates/appends only the selected region ID, preserves other regions and non-geometric metadata, installs accepted review digests and one schema-v3 audit, and supports one-step undo/redo/save/reopen. The exact v3 fields are `schema_version,type,mode,provider_id,metric_id,keyframe,keyframe_playback_index,keyframe_digest,region_id,direction,requested_count,generated_count,start_frame,end_frame,affected_frames,target_playback_indices,stop_frame,stop_reason,checkpoint_sha256,device,model_version,elapsed_ms,risk_summary,created_at`. Model score, mask, prompt, embeddings, absolute paths and unbounded diagnostics never enter V1 regions or the audit.

The four external settings are `PROJECT6_MODEL_PYTHON`, `PROJECT6_SAM2_CONFIG`, `PROJECT6_SAM2_CHECKPOINT` and `PROJECT6_SAM2_DEVICE=auto|cpu|cuda`. No package or checkpoint is installed/downloaded automatically. The evidence classes remain deliberately separate:

- 自动协议/安全：**PASS**；
- 真实 SAM Video 功能：**NOT RUN**；
- 真实可见 UI：**NOT RUN**；
- 真实精度结果（独立目标帧真值）：**NOT RUN**；
- 人工效率结果（同范围配对计时）：**NOT RUN**；
- CUDA 性能结果：**NOT RUN**。

The prior single-image SAM 2.1 Tiny CPU smoke is evidence only for single-frame Model Assist. It is not SAM Video functional, quality, UI, efficiency or CUDA evidence. The checked-in SAM Video acceptance allowlist remains empty, so no surgical media was opened for this classification.

Fresh final verification ran the repository-owned suite without changing its harness: **797 Python tests passed in 45.75 s**, followed by all **28** registered Godot invocations with status 0 and successful checked-log audits. A writable temporary XDG profile prevented unrelated user-settings write errors while retaining exactly the two expected headless-editor socket failure pairs. The aggregate emitted the intentional corrupt-PNG fixture diagnostics and ended with `PASS: complete Godot test suite`. Immediately afterward, the four specified Python SAM Video files passed **238 tests in 4.34 s**; the service, controller/read-only preview, exact-v3 command/persistence, and mounted Batch UI/re-anchor Godot gates each exited 0 and passed the repository `none` log profile. The final acceptance hardening additionally rejects excessive JSON nesting, equality-compatible numeric type substitutions, malformed direct-run containers, and unbound environment/CUDA provenance before evidence aggregation.

One-click training export remains paused at its pre-existing Task 4 review boundary. Its unresolved review issues were not repaired, upgraded or reclassified by the SAM Video Batch work.


## Part 3.2 / 3.3 alternative — similarity-gated Poly motion and edge refinement (2026-09-10)

When explicitly selected, `poly-sim-flow-edge-v1` uses a corrected keyframe as the human anchor: each accepted target receives its own motion-propagated polygon, optionally refined against local image edges. The Batch panel exposes threshold, range, overwrite/merge, read-only preview, Apply, verification and auto-next. It reports similarity stops, flow-quality stops and per-frame edge accepted/raw-flow fallback counts. This remains reproducible alternative/baseline evidence; it is not the current default and is never a silent fallback from SAM. Fixed-coordinate COPY is a separate explicit compatibility option and historical baseline.

### Frozen-input algorithm and safety contract

Godot snapshots at most 30 actual Source images as independent PNGs and freezes each image SHA-256, source-entry digest, record digest and verification state. Python decodes the same PNGs, resizes them to 64x64 grayscale with OpenCV `INTER_AREA`, and requires both adjacent-target and fixed-keyframe-target MAD to be **strictly below the visible threshold** (default **0.02**) before constructing optical flow. Source pixels and all frozen identities are checked again before preview acceptance and commit; a stale image, mapping, annotation or review state discards the plan.

OpenCV DIS estimates forward/backward motion. The sequential mask is checked against local appearance, texture, forward/backward support, area change and a direct prediction from the fixed human keyframe. The minimum flow score must be at least 0.65 and sequential/direct mask IoU at least 0.85. A failure in any reference Poly stops that direction at the current frame; the workflow never jumps over an unreliable frame.

The edge stage runs three GrabCut iterations only in a local six-pixel mask band with an eight-pixel ROI pad, and scores boundaries on a normalized Sobel map. It accepts the refined mask only when it is one hole-free component, does not touch the crop boundary, keeps raw IoU at least 0.85, area ratio within 0.80–1.25, Hausdorff distance at most 6 image pixels and edge-score gain at least 0.01. Expected gate failures retain the raw optical-flow mask exactly and surface the reason. Runtime/protocol errors, non-finite diagnostics or a fallback that changes the raw mask reject the whole plan.

The final polygon must remain one simple hole-free Model Output V1 ring, contain no more than 2,048 points and reproduce the mask with at least 0.99 IoU. No hole, multipolygon or persistent raster mask is introduced. Similarity, flow and edge scores are diagnostics only; applied targets remain unverified.

Preview and commit consume the same per-frame proposal. Overwrite retains only propagated reference polygons; merge updates the same IDs and retains target-only regions. `ApplyPropagationCommand` preserves target source/frame/time identity and commits every changed target plus a schema-v2 audit marker as one undo/redo item. The marker records algorithm ID, threshold, range, stop reasons and a complete bounded target-by-reference edge matrix; validation uses that immutable historical matrix rather than later keyframe membership. Adding or deleting a keyframe Poly after the batch therefore does not invalidate save/reopen of the existing audit. Model Output V1 records remain unchanged in shape, and the original model JSONL remains read-only.

### Independent synthetic IoU benchmark

`tests/python/polygon_benchmark.py` renders independently defined textured concave targets with known transforms. It runs the production path once with edge refinement and once with a forced raw-flow fallback, then rasterizes returned polygons against the independent target masks. The fresh record `/tmp/poly-edge-benchmark.json` used Python 3.14.7, OpenCV 4.14.0, NumPy 2.5.2 and seed 27. The similarity threshold is deliberately 1.0 in this geometry benchmark so it measures flow/edge behavior rather than scene segmentation.

| Synthetic case | Proposals | COPY mean IoU | Raw-flow mean IoU | Final mean IoU | Edge accepted / fallback |
|---|---:|---:|---:|---:|---:|
| translation | 6 | 0.523605 | 0.999850 | 0.999850 | 0 / 6 |
| reverse translation | 6 | 0.523605 | 0.999850 | 0.999850 | 0 / 6 |
| rotation | 3 | 0.753467 | 0.985876 | 0.985876 | 0 / 3 |
| deformation | 3 | 0.677299 | 0.991753 | 0.994630 | 1 / 2 |
| boundary offset | 1 | 0.851720 | 0.982675 | 0.999236 | 1 / 0 |

The translation/reverse minimum final IoU is 0.999701; rotation minimum is 0.979701; deformation minimum improves from raw 0.988085 to final 0.990757; boundary-offset final IoU is 0.999236. These exact results establish that motion propagation outperforms fixed COPY on these five fixtures and that accepted refinement improves the two constructed edge cases. They do **not** establish universal edge improvement or surgical-video accuracy. Expected fallback is a normal safe outcome, which is why translation and rotation have unchanged raw/final values.

Focused tests additionally cover default-threshold similarity refusal before flow, fixed-keyframe brightness drift, local evidence failure, occlusion/texture/area/anchor gates, topology and image-boundary refusal, cancellation, 32 MP/64 MiB/128 MiB budgets, stale snapshots, v2 marker persistence, overwrite/merge, exact preview commit and atomic undo/redo.

The feature-branch scoped Python gate passed **113 tests in 8.50 s**. Its pre-integration repository runner passed **465 Python tests in 36.47 s** and all invoked Godot entries with status 0, including the complete mounted suite, the historical fixed-COPY Batch UI fixture, no-candidate behavior, provider contract, Poly command/integration/service/UI suites and the Main boundary suite. The deliberately corrupt PNG fixtures emitted expected decoder diagnostics; the aggregate suite still ended with `PASS: complete Godot test suite`. The later merged authoritative result is the 524-test run recorded above.

### Endoscapes local qualitative path

The reproducible local fixture uses Endoscapes video 65, frames 11775–11875, keyframe 11800 and instance 0 (`gallbladder`, category 5). The source mask touches the top and bottom image boundaries; the builder explicitly removes the outer two pixels to create a bounded V1 seed. Provenance marks this as lossy and records source/seed counts, source hashes, retained IoU **0.9977630886** and polygon raster IoU **0.9990230362**. One pixel was insufficient after the actual Godot PNG round trip; three pixels broadened the candidate range, so two is the smallest measured safe fixture inset. This transformation is fixture preparation, not an algorithmic accuracy claim.

At threshold 0.02, the five-frame direct run produced only playback index 2 (original frame 11825), range `1..2`. Playback 0/original 11775 and playback 3/original 11850 stopped on local inconsistent/occluded evidence. The target GrabCut candidate contained a hole, so the production gate rejected it and kept the exact raw-flow mask. A separate 30-frame window again produced only original 11825, proving this example stops on local quality evidence rather than the 30-frame cap.

The historical pre-SAM mounted 1280x800 Main acceptance selected Poly under the then-current default, displayed threshold 0.02, previewed the exact candidate, applied it once, undid/redid one atomic command, saved/reopened, retained the v2 marker, confirmed the target, auto-advanced and reopened again. The baseline `model_output_v1.jsonl` SHA-256 remained unchanged. The local preview screenshot and raw/final overlays were visually inspected. This evidence belongs only to the explicitly selected Poly alternative and does not describe the current Batch default.

Only keyframe 11800 has an instance mask; target frames have no independent dense truth. Consequently this is evidence for the real-data path, safe fallback, persistence and human inspectability—not target-frame IoU, general Endoscapes accuracy, universal refinement benefit, automatic verification or a measured reduction in labelling time. Endoscapes images, masks, absolute dataset paths and generated evidence remain ignored and untracked. Reproduction details are in `docs/endoscapes-poly-acceptance.md`.

### Historical COPY evidence and remaining risk

The earlier `godot-rgb64-bilinear-mad-v1` COPY workflow covered synthetic frames 40–59 at threshold 0.02 and changed 19 targets after one keyframe correction. Its recorded boundary MAD values and persistence/UI evidence remain valid for that compatibility path, but its geometry is superseded as the default. Constructed diagnostics showed why: full-image MAD can accept a moving 20x20 target after copied geometry has reached IoU 0, and endpoint-only checks can miss a move-away-and-return failure.

The current design addresses that static-model mismatch with object-local bidirectional motion, fixed-anchor checks and conservative stops. It still cannot guarantee identity under similar-looking objects, severe occlusion, specular changes, blur or topology outside Model Output V1. A long accepted segment can accumulate mask-state error even with a fixed-keyframe comparison. Users must inspect interior candidates, correct a new human keyframe when quality drops, and treat `verified` as a human decision only. No `T_manual`/`T_batch` study has been run, so no percentage time-saving claim is made.

## Part 4 persistence, audit and file handoff

Part 4 implements the Assignment 4.1–4.4 file-handoff path. The production entry
`python/part4.py demo` generates images/model outputs, applies eight real edit and
review commands, waits for autosave, reopens, exports, independently validates,
and imports an explicitly simulated second model round. It does not train a model
or execute weights. The CLI and actual mounted Godot UI share the same services.
The interface agreement is `docs/part4-protocol.md`; reproducible CLI/UI steps are
in `docs/part4-review.md`. Tests and generated evidence remain local and ignored,
while the production demo does not depend on `tests/` or an existing `sample/`.

### Functional evidence

This initial-delivery record predates the strict 4.3 audit and repair. Fresh repair
counts and the remaining large-input gate are listed in the current repair entry below.

| Requirement | Observed result | Reproduction / evidence |
|---|---|---|
| 4.1 immutable baseline and restoration | Original baseline digest, final diff and accepted content survive save/reopen; V3 corrected records use `human_corrected`; legacy migration preserves exact prior bytes | `test_part4_repository.gd`, `test_part4_store_regression.gd`, `test_part4_optional_timestamps.gd`; demo `reopen_stable` |
| 4.1 autosave and lifecycle | 300 ms idle scheduling, request before 2 s during continuous edits; one writer, queued latest revision, external-write refusal, failure/retry, session guards, Save/Discard/Cancel | `test_part4_autosave.gd`, `test_part4_save_deadline.gd`, `test_part4_save_wait_races.gd`, `test_part4_save_failures.gd`, `test_part4_lifecycle.gd` |
| 4.2 exact final audit | Frames 12/13 geometry=2; frame24 label=1; frame36 added=1; frame72 deleted=1; frame90 track attributes=2; total6 changed frames/7 changed regions | `test/part4/history/output/part4-protected-demo-20260908/evidence.json`, JSON/CSV reports in its training package |
| 4.2 audit boundaries | ID reorder and numeric12/12.0 are equivalent; undo restores no diff; ID replacement becomes delete+add; simultaneous label/geometry events and class transfers counted; source/filled ignored | `test_part4_diff_edges.gd`, `test_part4_package_numbers.gd` |
| 4.3 coverage | Verified training includes6/120 and excludes114; review export contains120 with actual explicit/verified status; verified unchanged/empty frames are eligible, unverified empties are excluded | Production demo; `test_part4_package.gd`, `test_part4_package_review_fixes.gd` |
| 4.3 publication and interoperability | Hash/bytes/schema/coverage/review/audit/CSV validation; conflicting or damaged destination rejected; repeat content reuses package; UI and CLI artifacts byte-identical with the same package ID | `test_part4_parent_semantics.gd`; `test/part4/history/output/part4-ui-cli-parity.json` |
| 4.3 editor isolation | After a real editor rescan, training/review packages retain exactly six files and identical SHA values; independent validation, repeated export and raw PNG Source loading still pass | `test/part4/history/output/part4-editor-isolation.json`, `test_output_import_guard.py` |
| 4.4 new model round | Complete120-frame return validated before archival and active replacement; exact old V3 retained; new baseline/current predictions activated; verification/batch/undo reset | Production demo; `test_part4_rounds.gd`, `test_part4_round_ui.gd` |
| 4.4 failed preparation/commit | Wrong coverage, time, parent semantics, SHA or changed input leaves the old active file and UI intact; legacy binding preserves explicit coverage | Round backend/UI and parent semantic tests |
| Part3 regression | Poly similarity/flow/edge proposal, exact preview commit, v2 marker, undo/redo, persistence, verification and successful-save-only auto-advance; legacy 40–59 COPY workflow retained | polygon focused suites, mounted Endoscapes UI acceptance, `test_batch_workflow.gd`, `test_batch_ui.gd` |

Fresh full Python regression: **337 passed**, no skips. The complete Godot test
entry and independent polygon, image-region, advanced-edit, keyboard, brush,
fill, checked-history, assignment-editing, vertex and batch entries pass. The
additional **27 Part 4 behavioral suites** are recorded in
`test/part4/history/output/part4-gate-1788853027511915310/results.json`. The final integrated main
run and logs are in `test/part4/history/output/part4-main-acceptance-1788852895156475325/results.json`
(runtime commit `9c24ea8`). Numeric oracle tests compare
**12,230 IEEE binary64 values** with Python, including subnormals, midpoint ties,
long decimals,30fps timestamps and independent content/package digests. Nesting256
is accepted and257/510/511/512/600/10000 are rejected without VM stack errors.
Deliberately corrupt PNG fixtures produce expected decoder diagnostics; script
errors are not accepted as a passing gate.

Visible captures were inspected at `test/part4/history/output/part4-ui/main.png`,
`test/part4/history/output/part4-ui/export.png` and `test/part4/history/output/part4-ui-round-6157154.png`. The exported
Godot resource ZIP contains all three exact runtime feedback schemas; integrity
record: `test/part4/history/output/part4-export-resources.json`.

### Crash and failure evidence

`tests/benchmarks/part4_crash.py` launches and terminates only its own Godot
subprocess at deterministic barriers around the real atomic writer. After each
SIGKILL, independent Python validation and exact bytes recover:

| Termination point | Recovered active document |
|---|---|
| Temporary file partially written | Complete old V3 |
| Temporary file read back and validated | Complete old V3 |
| Immediately before atomic replacement | Complete old V3 |
| Immediately after atomic replacement | Complete new V3 |

Raw record: `test/part4/history/output/part4-crash-1788848841065271365/results.json`. This is a local
filesystem/process-crash guarantee at the latest successful save, not a power-loss
or multiwriter durability claim. Unsuccessful edits remain in memory until saved.
V1/V2 migration, invalid payload serialization, stale external SHA, unwritable
paths, missing artifacts, damaged digests, semantic tampering and round mismatches
are tested without replacing prior valid data. A malformed native JSON
serialization such as NaN-to-null is refused before publication.

`test_part4_export_cancel.gd` inserts2s I/O into the real package path: the UI
accepts cancellation immediately and continues287 process ticks while waiting;
no package is published. A second case cancels after actual publication and
preserves the valid package and its displayed path. This measures responsive
cancellation intent; an in-progress blocking filesystem call itself is not
preempted. Slow save and background-token tests also confirm progress callbacks
and continued event processing.

### Response and resource measurements

Historical measurements before the current Part 4.3 repair follow. They are retained
for comparison and are not current large-input acceptance; the repair entry below
records the two interrupted attempts and final resource preflight rejection.

Host: AMD Ryzen9 7945HX, Ubuntu22.04, Godot4.7.2-stable. The headless input probe
uses a producer thread every10ms, queues a timestamp, and dispatches an actual
`InputEventKey` through the SceneTree. Reported response includes main-thread
queueing. It does not load images or simulate GPU rendering; separately mounted
Main/UI tests and visible X11/GL Compatibility captures check the actual controls.
These measurements are not a human interaction study.

| Metric |120 frames ×20 regions |10,000 frames ×20 regions |
|---|---:|---:|
| Edit→successful autosave |p95 **868.231ms**,15 edits |48,183.399ms,1 edit |
| Save worker |p95 556.322ms,16 writes |48,112.848ms maximum,2 writes |
| Frozen snapshot preparation |p95 0.555ms |14.650ms,1 snapshot |
| Input response during save |p95 **13.274ms**,max13.672ms,n1234 |p95 **15.170ms**,max407.623ms,n4789 |
| Standalone full-review preview/diff |289.279ms |27,013.952ms |
| Full review export total |482.975ms |49,319.419ms |
| Export preview / artifact writing |221.250 /1.762ms |24,045.861 /71.716ms |
| Export semantic validation / atomic publication |216.389 /0.194ms |21,436.853 /0.120ms |
| Input response during diff/export |p95 **13.297ms**,max13.662ms,n76 |p95 **13.354ms**,max535.681ms,n7583 |
| Whole-process peak RSS |not measured |4,969.47MiB (4.85GiB) |

Raw measurements: `test/part4/history/output/part4-performance-120-206788/results.json`,
`test/part4/history/output/part4-performance-10000-193951/results.json` and
`test/part4/history/output/part4-large-1788849574176695631.monitor.json`.
Timing subtotals omit some serialization/hash/worker-message overhead, so they
need not sum to the total. Snapshot counts and distributions are stated explicitly;
the single large edit is not a statistical autosave-latency claim. The required
120-frame autosave p95≤1s and large-source input p95≤100ms targets pass. Large
sessions still take tens of seconds to persist/export, use substantial memory,
and show input tail spikes above100ms; lower-memory storage and tail-latency
optimization remain follow-up work. The2s continuous-edit bound is a save-request
bound, not a large-file completion deadline.

### Defects found and resolved

1. Reopening a workspace previously risked using corrections as the next model
   baseline. V3 stores immutable baseline provenance separately and restores
   corrections through the codec. Legacy data remains explicitly unknown until
   raw output is bound; implicit placeholders never become negative truth.
2. Native Godot JSON parsing changed some binary64 decimals by one ULP (including
   7/30), invalidating exact timestamps/digests. The shared ExactJson reader uses
   exact rounding and bounded nesting; cross-language bit/hash tests verify it.
3. Repeated full semantic decode made120-frame autosave p95 exceed1s; repeated
   string concatenation made large export disproportionately slow. Atomic saves
   now validate readback once and check equality to the frozen input; JSONL/CSV
   use one join. Fault tests preserve the original durability protections. Shared
   parent-package semantic validation also closes the earlier UI/CLI discrepancy.
   Legal Unicode U+0085/U+2028/U+2029 inside JSON strings now survive LF-only
   JSONL parsing in Python;9 real Godot exports and33 boundary cases cover it.
4. A post-integration Godot editor scan interpreted generated CSV reports as
   translation resources, added `.translation`/`.import` sidecars to old packages,
   and hit a native importer crash. The artifact bytes remained intact, but strict
   inventory validation correctly refused those directories. Package workers now
   create/preserve `output/.gdignore` outside each package, require an existing
   regular ignore ancestor for other in-project package destinations, and retain
   support for external output. JSON-only session/round storage stays independent
   of this report guard. No old files were removed and no package allowlist was
   relaxed. A fresh protected demo, actual editor rescan, exact inventory/hash
   comparison, independent validation, repeat reuse and Source texture reads pass
   in `test/part4/history/output/part4-editor-isolation.json`. That rescan used the local marker added
   during diagnosis; twelve isolated-project tests separately verify automatic
   marker creation, refusal boundaries and in-project JSON round archival.
   The engine's native fault was not
   symbolicated; the reproducible import trigger is isolated using Godot's
   [documented directory exclusion](https://docs.godotengine.org/en/stable/tutorials/best_practices/project_organization.html#ignoring-specific-folders).

The separate Part2.2/2.3 human-review boundary is unchanged. Part4 establishes file
handoff and independent round ingestion; model-team training, actual weight
quality, automatic correction merging and real surgical-video accuracy are outside
this acceptance.

### Part 4.1 strict requirement recheck (2026-09-08)

A fresh focused audit at runtime commit `33268e3` passed **19 acceptance groups**.
This includes independent V1/V3 validation and exact saved/exported record
comparison, actual sparse PNG Source → UI edit → timer save → reopen → export,
actual window-close signals and Ctrl+S, the existing failure/lifecycle tests,
unverified legacy full-data export, the 120-frame production demo, and four owned
subprocess crash boundaries. It is not a rerun of the earlier 337-test full suite.
The requirement-by-requirement report and complete logs are local at
`test/part4_1/REPORT.md` and
`test/part4_1/runs/20260908-162840-1788856120932484360/results.json`.

V3 remains the session envelope; each corrected record and exported JSONL line
conforms to Model Output V1 with `source: human_corrected`. Full-dataset export
uses the all-frame review option; the default training package remains a verified
subset. Process-crash recovery is limited to the latest successful local save.
The audit corrected an observation-time race in an old autosave test, preserving
its original source and failing diagnostics; no runtime code changed.

New audit artifacts are explicitly marked TEST ONLY under `test/part4_1/`.
The main workspace's historical Part 4 artifacts were relocated to
`test/part4/history/output/`: 31 top-level entries, 1,438 files, every file's
SHA-256 unchanged. `test/part4/history/path-map.json` resolves original paths
without rewriting historical evidence or package contents. Current links above
refer to their archived locations.

### Part 4.2 strict requirement recheck (2026-09-08)

At runtime commit `33268e3`, a fresh **8-group audit passed**, including **37
independent Python package tests**. A handwritten sparse-frame oracle verified
13 events, 11 distinct changed regions, all four required categories, optional
attribute events, complete before/after values, and exact per-class accounting.
CSV parsing independently recovered commas, quotes, newlines and Unicode labels.
Undo removed all final differences; redo and save/reopen restored identical
reports and package identity. Corrupt baselines and duplicate IDs were rejected.

The production 120-frame demo matched the assignment fixture: geometry=2,
label=1, added=1, deleted=1, attributes=2; 6 changed frames and 7 changed regions.
The training report covered 6 verified frames and the full review report covered
120 frames. A mounted Main/export workflow and CLI export of the same frozen
snapshot produced identical artifact bytes and package IDs. This UI check was
headless; it was not a new manual visual review.

Evidence is explicitly TEST ONLY at `test/part4_2/REPORT.md` and
`test/part4_2/runs/20260908-164605-1788857165221704472/results.json`.
The initial failed test fixture is retained: its JSON-derived floating frame IDs
were adapted to the internal review command's integer input before the passing
rerun. No runtime product code changed.

Part 4.2 passes for the current Part 4 UI/CLI package path with a trusted model
baseline. Reports live beside corrected data within the same package's
`reports/` and `data/` directories. Full audit requires the all-frame review
option; training summaries describe only their verified subset. Legacy Plugin
API V1 export remains a compatibility path without the full audit. Unknown
baseline reviews explicitly mark the audit unavailable, not zero differences.


### Historical Part 4.3 strict all-entrypoint recheck (2026-09-08, before repair)

The following records the preserved pre-repair audit; the repair acceptance entry below supersedes its current-status claims.

**The previous unqualified Part 4.3 PASS is superseded: strict acceptance is
BLOCKED pending a retained legacy entrypoint fix.** Current V2 Export/CLI file
handoff passes its functional checks. Fourteen diagnostic groups ran successfully,
including 37 independent Python package tests, but the strict audit exits 1
because a product defect was reproduced. Runtime code remains `33268e3` unchanged.

`Main.export_handoff()` at main.gd:995 calls the V1 plugin synchronously. A real
Main test with injected 2-second slow IO confirmed main-thread execution for
2086.573 ms with zero event-loop ticks. The default V2 UI path ran the same delay on
a worker and delivered 366 event-loop ticks over 2563.226 ms. The old callback remains wired;
the current top-level Export button does not use it. The legacy two-file package
also lacks the complete diff and is not a V2 handoff substitute.

The audit also records a separate original-plan deviation: top-level manifest
`created_at` is absent and rejected by the current schema. Assignment 4.3 itself
does not explicitly require that field. No runtime fix or schema relaxation was
made during this review. The existing sanitized round naming rule is now stated
in the consumer protocol as well as the design document.

Passed V2 evidence includes actual CLI demo, relocated receiver validation without
Godot, repeat/reused handoff, independent integrity/semantic checks, failures after
partial writing and before publication, cancellation/late completion, collision
preservation, actual UI failure/retry, and UI/CLI artifact byte parity. Fresh
120-frame x20-region measurement: export 668.719 ms, diff/export input response p95
13.166 ms, maximum 13.531 ms across 103 probes. It used headless SceneTree
input events; no new manual visual check or 10,000-frame rerun is claimed.

All artifacts are explicitly TEST ONLY at `test/part4_3/REPORT.md` and
`test/part4_3/runs/20260908-165907-1788857947587592708/results.json`.
The runner distinguishes `tests_passed: true` from
`strict_all_entrypoints_compliant: false`. Fix the old Main path and rerun the
slow-IO/cancel/failure gates before restoring an unconditional 4.3 completion claim.

Documentation regression: the old hard-coded Part4.3 PASS assertion was updated
to require BLOCKED and the confirmed legacy entrypoint explanation. Its original
source and failed log are preserved under test/part4_3/. The revised documentation
suite passes 12 tests; this does not resolve the product defect or change the
strict audit exit status.


### Historical Part 4.3 repair acceptance (2026-09-08, before memory optimization)

The old synchronous Main export and connected dialog are removed. UI and awaited
Main.export_package share TrainingExportController, with captured session/revision/
plugin, cancellation drainage and stale preview invalidation. Plugin API V1 remains
available only as the lower-level compatibility path. New training/review manifests
include strict UTC-second created_at; legacy omission and original creation times
are preserved on validated reuse. Receivers must upgrade their validators first.

At that retained historical gate, acceptance was **BLOCKED: 21/22 groups pass**. The only outstanding
gate is a fresh 10,000-frame x20-region response measurement. Two real attempts
stopped during initial V3 save at RSS 3864.9 / 4366.32 MiB when MemAvailable fell
below 1 GiB; neither completed measurement is claimed. The final gate checks for
6 GiB available before starting this workload (5 GiB child limit + 1 GiB headroom),
and rejects insufficient resources with exit 1. No old large-input result is reused.

Passed evidence: complete Godot suite (including V1 compatibility), Part3 batch
workflow/UI, Part4.1 19 groups, Part4.2 8 groups, 37 package Python tests, 78 targeted
reader tests, Godot writer/reader matrices and 12 documentation tests. Two-second
slow IO advances the actual UI/programmatic main loop 343 / 342 times on worker
execution. Cancel/late-publication/retry, sparse frames, optional time, full-precision
JSON/CSV, independent Python validation and UI/CLI parity remain covered.

Final 120x20 measurement (3 edited saves): snapshot p95 0.183 ms; autosave
including debounce p95 826.723 ms; export preview/write/validation/publication
205.855/0.786/247.675/0.117 ms; total 482.861 ms. Input p95 is
13.264 ms during save and 13.333 ms during preview/export; RSS 170.57 MiB,
no images loaded. This headless input-queue test does not claim new human visual
acceptance. Artifact reads per validation are measured at 3 before / 1 after using
strace. Source-order/duplicate checks, task-local schema reuse, immutable golden
IDs and all five artifact bytes pass; only created_at differs in new manifests.

TEST ONLY evidence and original failures are retained under
`test/part4_3/repair/20260908-171751/`; see `test/part4_3/REPORT.md` and
`gate3/results.json`. The strict runner now computes its status from assertions
and returns nonzero for any failed necessary check. Completion remains conditional
on the large current-run memory/response gate, not the repaired old entrypoint.


### Part 4.3 memory optimization acceptance (fresh recheck 2026-09-10)

**PASS.** Fresh strict gate: 22/22 groups, including Part4.1's 19 groups,
Part4.2's 8 groups, full Godot/V1 compatibility, Part3 batch workflow/UI,
independent Python package validation, creation-time compatibility, real
UI/programmatic slow-IO/cancel/retry and frozen UI/CLI artifact parity.
The approved memory implementation shares recursively immutable frames, removes
validation-only Stores, incrementally hashes frames, writes 64 KiB chunks and
streams artifacts sequentially. Full strict readback/equivalence/semantic checks
and atomic publication remain. See `docs/part4-memory.md`.

The merged runtime was rechecked after Match and Model Assist integration. All
22/22 groups passed, including both response measurements, documentation tests
and the final runtime-hash equality gate; no finding remained. Current TEST ONLY
results are in `test/part4_3/runs/20260910-113953-1789011593508518888/results.json`.

Same input, fresh completed prechange/optimized processes (VmHWM MiB):

| Fixture | Before | After | Reduction | Five artifacts + package ID |
|---|---:|---:|---:|---|
| 120 × 20 | 157.445 | 130.344 | 17.21% | PASS |
| 1,000 × 20 | 504.363 | 260.531 | 48.34% | PASS |
| 3,000 × 20 | 1271.855 | 556.574 | 56.24% | PASS |

Three new independent 10,000x20 processes completed under the **3072 MiB**
RSS/HWM budget with **1024 MiB** minimum system headroom (4096 MiB preflight).
Each large process performed an initial save and one edited save, preview and
complete export; each save/export input measurement has thousands of events.

| Run | Peak MiB | Edited save seconds | Export seconds | Save / export input p95 ms |
|---|---:|---:|---:|---:|
| 1 | 1606.969 | 40.183 | 40.902 | 13.376 / 13.364 |
| 2 | 1607.148 | 39.981 | 41.060 | 13.369 / 13.375 |
| 3 | 1606.875 | 40.457 | 40.961 | 13.419 / 13.359 |

The three package IDs and five artifact hashes match exactly. Large save duration
is one observation per process, not a statistical claim about save-time p95.
Final standard120x20 measured 20 edited saves: autosave including debounce p95
**785.209 ms**, peak **131.203 MiB**, save/export input p95
**13.264/13.401 ms**. Short prepare observations are
explicitly marked limited-sample; original save/export >10-event rules remain.

1000-frame stress fixtures with 50% / 100% corrected frames peaked at
276.391 / 310.992 MiB. A separate120-frame fixture with64 polygon vertices per
region peaked at262.047 MiB and saved in p95 **6.535 s** (3 observations).
That complex-geometry stress does not meet the standard-box 1-second target and
is not claimed to do so; it passes memory, input-response and output-validation
checks. Memory still scales with frames, geometry and changed data.

Save-worker phases from large repeat2 (two saves, observed maxima):
serialization4.233 s, buffered writes0.044 s, strict readback18.128 s,
equivalence4.308 s, semantic validation9.229 s, atomic publish0.0085 s.
These per-phase maxima need not come from the same save. Export phases and
raw sample counts are retained in the monitors. Individual large-run input tail
spikes remain (first run save555.682 ms, export306.133 ms); p95 compliance is
not a maximum-latency guarantee. Headless input-queue evidence and automated
Main interactions do not represent new human visual acceptance.

Code review found and fixed a long-scalar first-chunk failure hang and malformed
snapshot precondition errors. Their red logs remain; fresh first/middle-chunk
failure cleanup,43 malformed cases,384 before/after codec parity cases and
stream byte/hash/precision/cancellation tests pass. The measurement gate rejects
runtime errors despite exit0, insufficient save/export events, missing/nonfinite
metrics, wrong fixture identity and resource overruns.14 selftests and11
independent probes passed; optimized component timings and approved harness
hashes are independently required by final postvalidation.

All evidence is TEST ONLY in `test/part4_3/memory/20260908-115729/`:
`gate1/results.json`, `acceptance.json`, `paired_comparison.json`,
`repeat2_10000/monitor.json`, `repeat3_10000/monitor.json`, `final120/monitor.json`,
`review2/report.md` and `measurement_review/report.md`. Original failed large
runs and backups remain under `test/part4_3/repair/20260908-171751/`.
Lowering the limit alone would terminate the old workload earlier; the new
completed measurements demonstrate reduced actual memory without removing
strict validation or changing file contents.


### Part 4.4 targeted repair acceptance (fresh recheck 2026-09-10)

**PASS.** Fresh Part 4.4 gate: 10/10 groups. Shared-decoder regression:
Part 4.3 22/22, including Part 4.1 (19 groups), Part 4.2 (8 groups), full Godot
compatibility and both response benchmarks. Runtime hashes match the tested code.

The post-integration rerun again passed 10/10 groups and consumed the fresh
Part 4.3 22/22 gate above. Current TEST ONLY results are in
`test/part4_4/runs/20260910-114553/results.json`.

Returned manifests and JSONL now reject malformed UTF-8 before JSON parsing or
candidate creation. Actual CLI checks cover eight malformed encoding variants,
weights-only and unknown-field rejection, valid Chinese/literal U+FFFD, and an
optional opaque weights reference. Six mounted Main malformed-input cases retain
active bytes, source snapshot, Store/history, undo/redo and the current frame.

Demo now shares Source's source_sha256 with the session, packages and return.
Normal demo retains the full simulated loop. `demo --prepare-only` leaves a saved,
reviewed round1 and its matching round2 return. Actual Main opens that workspace,
edits/undoes/saves, reexports an identical parent package, previews and imports the
provided return, verifies the exact archive/reset, and reopens round2. The original
round UI test uses the public awaited export API and exits on prerequisite failure;
the final gate has no SCRIPT ERROR. Deliberately malformed inputs produce expected
Godot Unicode diagnostics before the application rejects them.

The agreement links all three authoritative schemas, summarizes region fields and
coverage/versioning, and has a rendered, inspected one-page PDF. The runbook gives
an explicit fresh UI starting round and explains why the completed demo cannot
reimport its own round2 return. Prior faulty demos and failed test records remain.

New regression measurements: standard 120 x 20 with 20 edits, autosave p95
785.911 ms; 10,000 x 20, peak RSS/HWM 1606.188 MiB, save/export input p95
13.457/13.435 ms. Large save remains about 39 seconds and this run contains one
measured large edit. These results preserve the earlier memory optimization;
they are not claims of real training or a human usability study.

TEST ONLY evidence: `test/part4_4/repair/20260909-002956/`, especially
`gate44/results.json`, `regression43/results.json`, `encoding/supplemental-result.json`
and `final-review.md`. Original blocked audit: `test/part4_4/runs/20260908-220116/`.
The original status/report and all failed fixtures are retained; see the current
`test/part4_4/REPORT.md` for requirement-level acceptance and replay commands.

### Poly motion propagation baseline (2026-09-09)

The batch UI now offers **Poly 轮廓运动**. OpenCV DIS flow carries an internal
mask through actual image frames and produces a distinct editable polygon for
each target. Fixed-anchor and local evidence checks stop unreliable directions.
Only matching Poly IDs are merged; the manual key and other objects are retained.
Candidates remain unverified. This is an implemented CPU baseline with synthetic
acceptance evidence, not a claim of surgical-video accuracy or completed human
usability acceptance. Usage and boundaries: [Poly propagation](docs/poly-propagation.md).

Fresh independent-truth measurements on AMD Ryzen 9 7945HX, Python 3.14.7,
OpenCV 4.14.0 and NumPy 2.5.2, at 224 × 192 pixels (seed 27):

| Scene | Accepted / all target frames | Fixed-copy mean mask IoU | Poly mean mask IoU | Poly minimum IoU | Engine time |
|---|---:|---:|---:|---:|---:|
| Translation | 6 / 6 | 0.523605 | 0.999850 | 0.999701 | 0.234 s |
| Reverse translation | 6 / 6 | 0.523605 | 0.999850 | 0.999701 | 0.179 s |
| Rotation | 3 / 3 | 0.753467 | 0.985876 | 0.979701 | 0.095 s |
| Local bend | 3 / 3 | 0.677299 | 0.991753 | 0.988085 | 0.110 s |

Every requested non-key target is included; no rejected frame is omitted from
these comparisons. Truth comes from known rendering transforms rather than the
estimated flow. Timings include PNG validation and propagation, exclude fixture
generation and process startup, and are single local observations. Detailed
frame values: `tmp/poly-benchmark-verified.json`. Reproduce with
`.venv/bin/python tests/python/polygon_benchmark.py --output tmp/poly-benchmark.json`.

| Requirement | Fresh evidence |
|---|---|
| Image-driven motion and concavity | 62 Python engine/CLI tests; translation in both directions, rotation, bend, static shape and original-coordinate restoration |
| Conservative reliability and V1 geometry | Weak texture, disappearance, occlusion, scene cut, holes, components, boundary contact, invalid rings, anchor drift and 2048-point candidate cap |
| Bounded Source processing | Real Godot service tests: 30-frame cap, original-ID gap, verified barrier, dimension change, unreadable image, stale mapping, timeout, malformed worker result and cancellation |
| Exact preview and atomic history | Distinct moving polygons, key/other-object preservation, same preview on commit, one undo/redo, stale key/target/review rejection |
| Save and review | Mounted headless Main: select Poly, preview, apply, save, reopen exact geometry and audit, manually verify, reopen verification |
| Compatibility | Complete core Godot suite, original batch workflow/UI, polygon geometry and Lasso vertex editing PASS; full Python suite **399 passed in 35.07 s** |
| Independent review | `tmp/poly-code-review.md`; no remaining Critical/Important finding. Output cap and post-cancel PID lookup issues were reproduced and corrected |

Consolidated run records and tested runtime hashes: `tmp/poly-acceptance.json`.

The core Godot suite emits expected decode diagnostics for deliberate corrupt-PNG
fixtures and exits 0 with its PASS marker. New Poly gates have no runtime errors.
The full Python run loads `project_env.sh` and first generates the existing Godot
V3 interoperability fixture; `tests/run_tests.sh` now includes that prerequisite
and all four new Poly gates. Its dependency-layout check excludes the existing
ignored `/test/` archive directory, preserving older benchmark project copies.
No baseline data or unrelated Part4 changes were removed.

The 0.65 quality score is not a calibrated probability. These scenes have strong
texture, modest motion and a clear foreground. Real surgical video, human edit
time, crowded targets, difficult lighting and false-acceptance rates are unmeasured.
The Main controls and layout bounds passed headless checks. A fresh visible
X11/GL Compatibility capture also verified the delivered Poly preview and the
seven-tool surface; that scripted capture still does not count as human visual
acceptance, which remains pending.
