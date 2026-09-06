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
source scripts/project_env.sh
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

Part 3.1 is `PASS` on the measured host. The client imports an FFmpeg-readable video in the background, opens the resulting indexed source, provides Play/Pause, Previous, Next and timeline seek, displays explicit frame/time plus read-only actual FPS, and keeps decoded image pixels behind a 12-texture LRU cache. The displayed `Time HH:MM:SS.mmm` is derived from the committed frame entry's immutable `time_s`, not elapsed wall-clock playback time. Part 3.2 and Part 3.3 remain incomplete and are not claimed by this result.

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

Audio playback, codec-level seeking, background `ImageTexture` creation, prefetching, looping and all Part 3.2 batch-labelling semantics are out of scope. In particular, the existing similarity scores and range-propagation primitive do not constitute the required Part 3.2 keyframe/verification workflow, so Part 3.2 and its Part 3.3 measurement remain `BLOCKED`.
