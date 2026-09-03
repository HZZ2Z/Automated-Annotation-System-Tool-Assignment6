# Dataset Explorer and MITK-Style 2D Toolbar Design

> Status: approved design for the frontend information-architecture adjustment.
> This document narrows the change to UI composition and preserves the verified Part 1 behavior.

## 0. Binding development rules

The teacher's assignment remains the highest-priority requirement source. This change must continue
to follow its recommended engineering style:

- use MITK as an interaction reference, not as a dependency or a requirement to reproduce every
  segmentation feature;
- keep the Godot client componentized and keep Source, Render, Edit, and Feedback behind explicit
  plugin interfaces;
- give every UI component one clear responsibility and a small, typed signal/method boundary;
- preserve human-readable code, stable interfaces, and extension points that a teammate can
  maintain without reading unrelated internals;
- prefer required, working behavior over broad but brittle functionality;
- never claim a reserved control is an implemented assignment feature.

The source-of-truth order for this change is:

1. `docs/Project_6_Automated_Annotation_System_Assignment.md`;
2. the user's approved decisions in this design discussion;
3. this change-specific design;
4. the earlier system design and implementation plan;
5. task-local implementation choices.

This document explicitly replaces the earlier protected requirement that the five edit tools stay
on the left. The approved shell now uses a dataset explorer on the left and a flat 2D tool palette
under the inspector on the right. All other protected Part 1 behavior remains in force.

## 1. Purpose

Restructure the existing Godot frontend so that:

- the left side resembles a focused VS Code file explorer for the currently opened dataset;
- the center remains the real annotation viewport;
- the right side resembles MITK's property-above, flat-tools-below layout;
- the existing source-opening, rendering, editing, history, and timeline behavior is reused rather
  than rewritten;
- future 2D tools have stable visible positions and identifiers without being represented as
  implemented functionality.

This is an information-architecture change. It is not permission to redesign the data contract,
plugin API, annotation store, renderer, edit commands, or source lifecycle.

## 2. Scope

### 2.1 Included

- A new `DatasetExplorer` UI component for the active source only.
- A resizable three-column workspace: dataset explorer, annotation viewport, right sidebar.
- Moving the existing `ToolPanel` into the right sidebar below `InspectorPanel`.
- A flat MITK-style four-column tool grid containing twelve stable slots.
- Five existing functional tools and seven reserved tool controls.
- A single unavailable-tool signal and a non-mutating `待开发` status response.
- Structure, component, integration, regression, and visual acceptance tests.

### 2.2 Excluded

- A general operating-system file manager.
- Editing, renaming, deleting, dragging, or writing files from the explorer.
- File previews, source tabs, text editors, context menus, and recent-workspace management.
- A docking framework or plugin-driven window manager.
- Implementations of Subtract, Lasso, Close, Paint, Wipe, Region Growing, or Live Wire.
- New annotation geometry, pixel-mask storage, segmentation groups, label locking, 3D tools, or
  interpolation.
- Changes to Source, Render, Edit, or Feedback plugin interface version 1.
- Unrelated visual theming or refactoring of `AnnotationMain`.

## 3. Approved layout

The root layout remains a vertical application shell:

```text
MainVBox
├── TopToolbar
├── WorkspaceSplit (HSplitContainer)
│   ├── DatasetExplorerContainer        minimum width: 220 px
│   │   └── DatasetExplorer
│   └── ContentSplit (HSplitContainer)
│       ├── ViewportPanel               expanding center
│       │   └── AnnotationViewport
│       └── RightSidebarContainer       minimum width: 320 px
│           └── RightSidebar
│               ├── InspectorScroll     expanding/scrollable
│               │   └── InspectorPanel
│               ├── Separator
│               └── ToolPanel           fixed at the bottom
├── TimelinePanel
└── StatusBar
```

`TopToolbar`, `AnnotationViewport`, `TimelinePanel`, and `StatusBar` retain their existing user
responsibilities. The nested split containers allow the reviewer to resize the left and right
panels without introducing a general docking system.

The baseline acceptance viewport remains 1280 x 800. At that size, the center viewport must remain
usable, the inspector must scroll instead of clipping, and all tool labels must remain readable.

## 4. Dataset Explorer

### 4.1 Responsibility

`DatasetExplorer` renders a lightweight view of the source that has already been accepted by the
existing source-opening transaction. It does not open, validate, decode, cache, or mutate source
data itself.

### 4.2 Display model

For a normalized dataset, the hierarchy is:

```text
DATASET
└── <dataset display name>
    ├── Frames (<count>)
    │   ├── <manifest frame path 0>
    │   ├── <manifest frame path 1>
    │   └── ...
    ├── manifest.json
    └── model_output_v1.jsonl
```

Only metadata files that actually exist are shown. For a standalone image, the tree contains the
real image and one virtual frame entry; it does not invent manifest or annotation files on disk.
Before any source is open, it shows `No dataset open`.

The view model is a deep-copied dictionary with this logical shape:

```text
display_name: String
source_path: String
frames: Array[{ index: int, label: String, path: String }]
artifacts: Array[{ label: String, path: String }]
```

It contains labels and paths only. It never contains frame textures or annotation records.

### 4.3 Public boundary

```text
populate(view_model: Dictionary) -> void
select_frame(index: int) -> bool
clear() -> void
signal frame_requested(index: int)
signal view_model_rejected(message: String)
```

- Clicking a valid frame emits `frame_requested` exactly once.
- Programmatic `select_frame` updates highlight and visibility without emitting navigation.
- Artifact rows are informational and do not open an editor.
- Invalid indices are refused without changing the current selection.
- An invalid view model leaves the existing tree unchanged and emits one bounded
  `view_model_rejected` message for `AnnotationMain` to show in the status bar.

### 4.4 Transactional synchronization

`AnnotationMain` constructs the explorer view model from the accepted open path and the staged
manifest. It calls `populate` only after the existing source, store, renderer, and edit-plugin
candidate transaction has committed successfully.

If opening or staging a replacement fails, no explorer method is called. The previous explorer,
image, annotations, selected region, frame, history, and active edit gesture remain unchanged.

After a successful frame change from the explorer, timeline, transport buttons, playback, or a
direct seek, `AnnotationMain` calls `select_frame`. This one-way display update must not create a
second seek request.

## 5. Flat MITK-style 2D tool palette

### 5.1 Visual arrangement

The tool palette has a single `2D Tools` heading and one flat four-column grid. It has no category
headings or tabs.

```text
Add Box       Subtract       Lasso          Fill
Erase         Close          Paint          Wipe
Region Growing Live Wire     Selection      Move / Resize
```

The order follows the supplied MITK 2D guide where possible, with the assignment-required
`Move / Resize` appended as the twelfth slot. Each slot uses an original icon, a visible text label,
and a tooltip. The design may take visual cues from MITK but must not copy MITK assets.

### 5.2 Tool registry

`ToolPanel` owns one declarative tool-description table. Every entry has:

```text
id: StringName
label: String
implemented: bool
tooltip: String
```

The stable inventory is:

| Position | Label | Stable ID | State in this change |
|---:|---|---|---|
| 1 | Add Box | `box` | implemented, existing behavior |
| 2 | Subtract | `subtract` | reserved |
| 3 | Lasso | `lasso` | reserved |
| 4 | Fill | `fill` | implemented, existing behavior |
| 5 | Erase | `delete` | implemented, existing behavior |
| 6 | Close | `close` | reserved |
| 7 | Paint | `paint` | reserved |
| 8 | Wipe | `wipe` | reserved |
| 9 | Region Growing | `region_growing` | reserved |
| 10 | Live Wire | `live_wire` | reserved |
| 11 | Selection | `select` | implemented, existing behavior |
| 12 | Move / Resize | `move` | implemented, existing behavior |

Existing internal IDs remain unchanged so the Edit plugin, keyboard behavior, and command history
do not need migration.

### 5.3 Signals and unavailable behavior

`ToolPanel` exposes two distinct intent signals:

```text
signal tool_requested(tool_id: StringName)
signal unavailable_tool_requested(tool_id: StringName)
```

- Clicking one of the five implemented tools emits `tool_requested` and preserves the existing
  mutually exclusive pressed state.
- Clicking a reserved slot emits only `unavailable_tool_requested`.
- `AnnotationMain` handles the unavailable signal by setting the status bar text to exactly
  `待开发`.
- A reserved click does not change the active tool, call the Edit plugin, start a gesture, create a
  command, change history, change selection, or mutate annotation data.
- Reserved controls remain visually available rather than disabled so the planned layout and
  click response can be reviewed.

The reserved tools do not receive empty Edit-plugin methods or separate placeholder scripts. One
UI-level unavailable boundary is easier to audit and avoids making unfinished behavior look like a
valid plugin implementation. A future tool becomes functional by implementing and testing the
behavior in the Edit stage, then changing its descriptor state and routing it through
`tool_requested`.

## 6. Inspector and direct actions

`InspectorPanel` remains the selected-region property editor. Its existing `Delete Region` button
continues to delete the current selection immediately. The grid's `Erase` control continues to use
the existing click-to-delete edit mode. These are deliberately distinct interactions.

Relabel, track ID, geometry values, confidence display, kind display, and fill state stay in the
inspector. The layout change must not duplicate their business logic inside `ToolPanel`.

The inspector is placed inside a `ScrollContainer` so its fields remain reachable when the window
height is constrained. The 2D tool grid remains visible below the scrolling area.

## 7. Files and ownership

Expected implementation files are limited to:

- new `client/ui/dataset_explorer.tscn`;
- new `client/ui/dataset_explorer.gd`;
- updated `client/app/main.tscn` for composition and layout;
- targeted updates to `client/app/main.gd` for component wiring and view-model coordination;
- updated `client/ui/tool_panel.tscn` and `client/ui/tool_panel.gd`;
- focused Godot tests and the test runner;
- documentation references affected by the approved left/right layout contract.

Source, Render, Edit, Feedback, Store, History, annotation schemas, taxonomy, and Python modules are
not expected to change. Discovering a genuine need to change one of those boundaries upgrades the
task and stops implementation for a new design decision.

## 8. Error handling

- Explorer population is an all-at-once UI replacement after source commit.
- Invalid explorer view-model entries produce a bounded status error and do not corrupt the tree.
- An explorer navigation request outside the accepted manifest range is refused and preserves the
  current frame.
- Reserved tools produce only `待开发`; they never produce a stack trace or silent no-op.
- Existing source-open errors remain failure-atomic and retain the active source and visible UI.
- Node-path changes must be updated consistently in `AnnotationMain` and tests; a scene that cannot
  resolve a required component is a hard test failure.

## 9. Test-first implementation and acceptance

Implementation starts with failing tests in this order:

1. `DatasetExplorer` component tests: empty state, populate, real hierarchy, frame request,
   programmatic selection without re-emission, invalid index, and clear.
2. `ToolPanel` tests: twelve positions, stable IDs, five functional routes, seven unavailable
   routes, exact `待开发` coordination, and no active-tool change for reserved controls.
3. Frontend structure tests: dataset explorer on the left, real viewport in the center, inspector
   and flat tool grid on the right, and absence of the old left tool panel.
4. Main integration tests: successful source population, single-image representation, failed-open
   preservation, and explorer/timeline/playback synchronization.
5. Existing ToolPanel, Inspector, Edit, undo/redo, keyboard, source, renderer, playback, plugin,
   feedback, Python contract, sample, and frame-source regression suites.

Final acceptance requires:

- all Python and Godot tests passing;
- `git diff --check` passing;
- a manual 1280 x 800 single-image check showing the left explorer, visible image, right inspector,
  and right-bottom tool grid;
- a manual normalized-sample check showing tree-to-frame navigation and current-frame highlight;
- a reserved-tool click visibly showing `待开发` while the active tool and annotation state remain
  unchanged;
- a failed replacement source preserving the explorer and visible image;
- no claim that the seven reserved tools are implemented assignment features.

## 10. Reference interpretation

The supplied `MITK_2D_Annotation_Tools_Guide.docx` is a design reference, not executable
instructions and not a repository runtime dependency. Its eleven-tool ordering and flat palette
inform the visual layout. Its pixel-mask semantics do not override this project's versioned
box/polygon region contract.

The assignment requires only a representative MITK-inspired 2D subset and explicitly allows
optional polygon drawing. Therefore visible reserved positions improve planned consistency, but
only tested, data-valid behavior counts toward assignment completion.
