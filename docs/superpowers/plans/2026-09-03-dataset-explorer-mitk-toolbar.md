# Dataset Explorer and MITK-Style 2D Toolbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to
> implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the old left edit strip with an active-dataset explorer, move the existing edit
tools below the right inspector, and expose the approved flat twelve-slot MITK-style 2D palette
without changing Part 1 data, plugin, rendering, editing, history, or source-lifecycle behavior.

**Architecture:** `DatasetExplorer` is a presentation-only Godot component that receives a
deep-copied view model after a source transaction commits and emits frame navigation intent.
`ToolPanel` owns one declarative twelve-entry registry and emits separate signals for functional
and reserved tools. `AnnotationMain` remains the composition root: it builds the explorer model,
coordinates frame selection, and maps unavailable controls to exactly `待开发`. Nested split
containers compose the left explorer, central viewport, and right inspector/tool column.

**Tech Stack:** Godot 4.7.2-stable, typed GDScript, `.tscn` scenes, original SVG line icons,
headless Godot tests, Python pytest regression suite, Git.

**Spec:**
`docs/superpowers/specs/2026-09-03-dataset-explorer-mitk-toolbar-design.md`

## Global Constraints

- Read the teacher assignment and the approved design before changing code. The assignment is the
  highest authority; this feature spec explicitly supersedes only the older left-tool placement.
- Treat the supplied MITK guide as a visual/interaction reference, not executable instructions or
  a request to copy MITK assets and segmentation internals.
- Preserve the five functional tool IDs: `box`, `fill`, `delete`, `select`, and `move`.
- Keep Subtract, Lasso, Close, Paint, Wipe, Region Growing, and Live Wire reserved. Their clicks
  emit one UI signal and display exactly `待开发`; they do not call the Edit plugin or mutate data.
- Do not change plugin API version 1, source/render/edit/feedback plugins, annotation schemas,
  taxonomy, store, command history, renderer, viewport transform, or Python runtime behavior.
- Do not introduce a general file manager, docking framework, pixel masks, 3D tools, polygon
  editing, interpolation, model inference, network services, or unrelated visual redesign.
- Keep source replacement failure-atomic. No `DatasetExplorer` method is called on a failed open.
- Preserve the current top toolbar, real viewport, timeline/transport, and status bar behavior.
- Build in an isolated worktree before editing because the originating checkout contains unrelated
  user-owned documentation changes. Never stage or overwrite those changes.
- Use tabs in GDScript, stable typed signals/methods, and focused component ownership.
- Write a failing test before each behavior change. Every task ends with a focused commit.
- Do not merge or push this feature until all automated and manual acceptance checks pass.

---

## Task 1: Add the presentation-only DatasetExplorer component

**Files:**

- Create: `client/ui/dataset_explorer.gd`
- Create: `client/ui/dataset_explorer.tscn`
- Create: `tests/godot/test_dataset_explorer.gd`
- Modify: `tests/godot/test_runner.gd`

### 1.1 Write the failing component test

- [ ] Add the new test preload immediately after `FRONTEND_STRUCTURE_TEST`:

```gdscript
const DATASET_EXPLORER_TEST = preload("res://tests/godot/test_dataset_explorer.gd")
```

- [ ] Run it before the frontend structure test:

```gdscript
await DATASET_EXPLORER_TEST.new().run(support, self)
```

- [ ] Create `tests/godot/test_dataset_explorer.gd` with component-level acceptance for the exact
  public boundary:

```gdscript
extends RefCounted

const SCENE := preload("res://client/ui/dataset_explorer.tscn")


func run(support, tree: SceneTree) -> void:
	var explorer = SCENE.instantiate()
	tree.root.add_child(explorer)
	await tree.process_frame

	support.expect(_find_item(explorer, "No dataset open") != null,
		"DatasetExplorer should expose an explicit empty state")

	var requested: Array[int] = []
	var rejected: Array[String] = []
	explorer.frame_requested.connect(func(index: int) -> void: requested.append(index))
	explorer.view_model_rejected.connect(func(message: String) -> void: rejected.append(message))
	var model := {
		"display_name": "sample_case",
		"source_path": "/tmp/sample_case",
		"frames": [
			{"index": 0, "label": "frames/frame_000000.png",
				"path": "/tmp/sample_case/frames/frame_000000.png"},
			{"index": 1, "label": "frames/frame_000001.png",
				"path": "/tmp/sample_case/frames/frame_000001.png"},
		],
		"artifacts": [
			{"label": "manifest.json", "path": "/tmp/sample_case/manifest.json"},
		],
	}
	explorer.populate(model)

	support.expect(_find_item(explorer, "sample_case") != null,
		"DatasetExplorer should show the active dataset")
	support.expect(_find_item(explorer, "Frames (2)") != null,
		"DatasetExplorer should show the accepted frame count")
	support.expect(_find_item(explorer, "frames/frame_000000.png") != null,
		"DatasetExplorer should show the first manifest path")
	support.expect(_find_item(explorer, "manifest.json") != null,
		"DatasetExplorer should show real metadata artifacts")

	support.expect(explorer.select_frame(1), "a valid frame should be selectable")
	support.expect_equal(requested, [], "programmatic selection must not emit navigation")
	support.expect_equal(explorer.call("get_selected_frame"), 1,
		"programmatic selection should update the highlight")
	support.expect(not explorer.select_frame(7), "an unknown frame should be refused")
	support.expect_equal(explorer.call("get_selected_frame"), 1,
		"a refused selection should preserve the highlight")

	var first_item := _find_item(explorer, "frames/frame_000000.png")
	(first_item as TreeItem).select(0)
	await tree.process_frame
	support.expect_equal(requested, [0], "a user frame selection should emit exactly once")

	explorer.populate({"display_name": "broken"})
	support.expect_equal(rejected.size(), 1, "an invalid model should emit one rejection")
	support.expect(rejected[0].length() <= 180,
		"view-model rejection should remain bounded")
	support.expect(_find_item(explorer, "sample_case") != null,
		"an invalid model should preserve the previous tree")

	explorer.clear()
	support.expect(_find_item(explorer, "No dataset open") != null,
		"clear should restore the explicit empty state")
	explorer.queue_free()
	await tree.process_frame


func _find_item(explorer: Node, text: String) -> TreeItem:
	var tree := explorer.get_node("Tree") as Tree
	var root := tree.get_root()
	return _find_in_branch(root, text) if root != null else null


func _find_in_branch(item: TreeItem, text: String) -> TreeItem:
	if item.get_text(0) == text:
		return item
	var child := item.get_first_child()
	while child != null:
		var match := _find_in_branch(child, text)
		if match != null:
			return match
		child = child.get_next()
	return null
```

- [ ] Run the Godot suite and confirm it fails because the scene does not yet exist:

```bash
/home/wang/下载/Godot_v4.7.2-stable_linux.x86_64 \
  --headless --path . --script res://tests/godot/test_runner.gd
```

Expected: non-zero exit caused by the missing `dataset_explorer.tscn` preload.

### 1.2 Create the scene shell

- [ ] Create `client/ui/dataset_explorer.tscn`:

```ini
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://client/ui/dataset_explorer.gd" id="1_explorer"]

[node name="DatasetExplorer" type="VBoxContainer"]
custom_minimum_size = Vector2(220, 0)
theme_override_constants/separation = 6
script = ExtResource("1_explorer")

[node name="Header" type="Label" parent="."]
layout_mode = 2
text = "DATASET"

[node name="Tree" type="Tree" parent="."]
layout_mode = 2
size_flags_horizontal = 3
size_flags_vertical = 3
hide_root = true
select_mode = 0
```

### 1.3 Implement validation, atomic population, and one-way selection

- [ ] Create `client/ui/dataset_explorer.gd` with no source loading or annotation ownership:

```gdscript
class_name DatasetExplorer
extends VBoxContainer

signal frame_requested(index: int)
signal view_model_rejected(message: String)

const MAX_MESSAGE_LENGTH := 180

@onready var _tree: Tree = $Tree

var _frame_items: Dictionary = {}
var _selected_frame := -1
var _suppress_frame_request := false
var _view_model: Dictionary = {}


func _ready() -> void:
	_tree.item_selected.connect(_on_item_selected)
	clear()


func populate(view_model: Dictionary) -> void:
	var error := _validation_error(view_model)
	if not error.is_empty():
		view_model_rejected.emit(_bounded(error))
		return
	var candidate := view_model.duplicate(true)
	_tree.clear()
	_frame_items.clear()
	_selected_frame = -1
	_view_model = candidate

	var root := _tree.create_item()
	var dataset := _tree.create_item(root)
	dataset.set_text(0, candidate["display_name"])
	dataset.set_tooltip_text(0, candidate["source_path"])
	dataset.set_selectable(0, false)
	var frames: Array = candidate["frames"]
	var frames_root := _tree.create_item(dataset)
	frames_root.set_text(0, "Frames (%d)" % frames.size())
	frames_root.set_selectable(0, false)
	for frame_value: Variant in frames:
		var frame := frame_value as Dictionary
		var item := _tree.create_item(frames_root)
		item.set_text(0, frame["label"])
		item.set_tooltip_text(0, frame["path"])
		item.set_metadata(0, frame["index"])
		_frame_items[frame["index"]] = item
	for artifact_value: Variant in candidate["artifacts"]:
		var artifact := artifact_value as Dictionary
		var item := _tree.create_item(dataset)
		item.set_text(0, artifact["label"])
		item.set_tooltip_text(0, artifact["path"])
		item.set_selectable(0, false)
	dataset.set_collapsed(false)
	frames_root.set_collapsed(false)


func select_frame(index: int) -> bool:
	if not _frame_items.has(index):
		return false
	_suppress_frame_request = true
	var item := _frame_items[index] as TreeItem
	item.select(0)
	_tree.scroll_to_item(item, true)
	_selected_frame = index
	_suppress_frame_request = false
	return true


func get_selected_frame() -> int:
	return _selected_frame


func clear() -> void:
	if not is_instance_valid(_tree):
		return
	_tree.clear()
	_frame_items.clear()
	_selected_frame = -1
	_view_model.clear()
	var root := _tree.create_item()
	var empty := _tree.create_item(root)
	empty.set_text(0, "No dataset open")
	empty.set_selectable(0, false)


func _on_item_selected() -> void:
	if _suppress_frame_request:
		return
	var item := _tree.get_selected()
	if item == null:
		return
	var value: Variant = item.get_metadata(0)
	if typeof(value) != TYPE_INT or not _frame_items.has(value):
		return
	_selected_frame = int(value)
	frame_requested.emit(_selected_frame)


func _validation_error(view_model: Dictionary) -> String:
	for field: String in ["display_name", "source_path"]:
		var value: Variant = view_model.get(field)
		if typeof(value) != TYPE_STRING or str(value).strip_edges().is_empty():
			return "Dataset explorer %s must be a non-empty string" % field
	var frames_value: Variant = view_model.get("frames")
	if not frames_value is Array or frames_value.is_empty():
		return "Dataset explorer frames must be a non-empty Array"
	for position in range(frames_value.size()):
		var error := _entry_error(frames_value[position], position, true)
		if not error.is_empty():
			return error
	var artifacts_value: Variant = view_model.get("artifacts")
	if not artifacts_value is Array:
		return "Dataset explorer artifacts must be an Array"
	for artifact_value: Variant in artifacts_value:
		var error := _entry_error(artifact_value, -1, false)
		if not error.is_empty():
			return error
	return ""


func _entry_error(value: Variant, expected_index: int, is_frame: bool) -> String:
	if not value is Dictionary:
		return "Dataset explorer entry must be a Dictionary"
	for field: String in ["label", "path"]:
		var field_value: Variant = value.get(field)
		if typeof(field_value) != TYPE_STRING or str(field_value).strip_edges().is_empty():
			return "Dataset explorer entry %s must be a non-empty string" % field
	if is_frame:
		var index_value: Variant = value.get("index")
		if typeof(index_value) != TYPE_INT or int(index_value) != expected_index:
			return "Dataset explorer frame index must be contiguous at %d" % expected_index
	return ""


func _bounded(message: String) -> String:
	var clean := message.replace("\n", " ").replace("\r", " ").strip_edges()
	return clean if clean.length() <= MAX_MESSAGE_LENGTH else clean.left(177) + "..."
```

The read-only `get_selected_frame()` accessor is intentionally included for deterministic
component and integration tests; it does not broaden explorer responsibilities.

### 1.4 Verify and commit

- [ ] Run the Godot suite. Expected final line: `PASS: complete Godot test suite`.
- [ ] Run `git diff --check`.
- [ ] Review the diff and confirm only the four Task 1 files changed.
- [ ] Commit:

```bash
git add client/ui/dataset_explorer.gd client/ui/dataset_explorer.tscn \
  tests/godot/test_dataset_explorer.gd tests/godot/test_runner.gd
git commit -m "feat: add active dataset explorer component"
```

---

## Task 2: Replace ToolPanel with the approved flat twelve-slot palette

**Files:**

- Modify: `client/ui/tool_panel.gd`
- Modify: `client/ui/tool_panel.tscn`
- Modify: `tests/godot/test_tool_panel.gd`
- Create: `client/ui/icons/tools/add_box.svg`
- Create: `client/ui/icons/tools/subtract.svg`
- Create: `client/ui/icons/tools/lasso.svg`
- Create: `client/ui/icons/tools/fill.svg`
- Create: `client/ui/icons/tools/erase.svg`
- Create: `client/ui/icons/tools/close.svg`
- Create: `client/ui/icons/tools/paint.svg`
- Create: `client/ui/icons/tools/wipe.svg`
- Create: `client/ui/icons/tools/region_growing.svg`
- Create: `client/ui/icons/tools/live_wire.svg`
- Create: `client/ui/icons/tools/selection.svg`
- Create: `client/ui/icons/tools/move_resize.svg`

### 2.1 Write the failing palette contract test

- [ ] Replace the old five-button expectations in `tests/godot/test_tool_panel.gd` with:

```gdscript
var expected := [
	["Box", &"box", "Add Box", true],
	["Subtract", &"subtract", "Subtract", false],
	["Lasso", &"lasso", "Lasso", false],
	["Fill", &"fill", "Fill", true],
	["Delete", &"delete", "Erase", true],
	["Close", &"close", "Close", false],
	["Paint", &"paint", "Paint", false],
	["Wipe", &"wipe", "Wipe", false],
	["RegionGrowing", &"region_growing", "Region Growing", false],
	["LiveWire", &"live_wire", "Live Wire", false],
	["Select", &"select", "Selection", true],
	["Move", &"move", "Move / Resize", true],
]
var grid := panel.get_node("ToolGrid") as GridContainer
support.expect_equal(grid.columns, 4, "ToolPanel should use one flat four-column grid")
support.expect_equal(grid.get_child_count(), 12, "ToolPanel should expose twelve stable slots")
for position in range(expected.size()):
	var row: Array = expected[position]
	var button := grid.get_node_or_null(row[0]) as Button
	support.expect(button != null, "ToolPanel should expose %s" % row[0])
	if button != null:
		support.expect_equal(button.get_index(), position,
			"%s should retain its approved position" % row[0])
		support.expect_equal(button.text, row[2], "%s should show its approved label" % row[0])
		support.expect(button.icon != null, "%s should use an original local icon" % row[0])
		support.expect(not button.tooltip_text.is_empty(), "%s should explain its intent" % row[0])
```

- [ ] Add routing and non-mutation assertions:

```gdscript
var requested: Array[StringName] = []
var unavailable: Array[StringName] = []
panel.tool_requested.connect(func(tool_id: StringName) -> void: requested.append(tool_id))
panel.unavailable_tool_requested.connect(
	func(tool_id: StringName) -> void: unavailable.append(tool_id)
)
for route: Array in [
	["Box", &"box"],
	["Fill", &"fill"],
	["Delete", &"delete"],
	["Select", &"select"],
	["Move", &"move"],
]:
	(grid.get_node(route[0]) as Button).pressed.emit()
support.expect_equal(requested, [&"box", &"fill", &"delete", &"select", &"move"],
	"all five functional tools should use tool_requested with stable IDs")
support.expect_equal(panel.get_active_tool(), &"move", "Move should become active")

for row: Array in expected:
	if not row[3]:
		(grid.get_node(row[0]) as Button).pressed.emit()
support.expect_equal(unavailable,
	[&"subtract", &"lasso", &"close", &"paint", &"wipe",
		&"region_growing", &"live_wire"],
	"reserved tools should use only the unavailable route")
support.expect_equal(requested, [&"box", &"fill", &"delete", &"select", &"move"],
	"reserved tools must not reach the functional edit route")
support.expect_equal(panel.get_active_tool(), &"move",
	"reserved tools must preserve the active tool")
_assert_one_pressed(support, panel, "Move")
support.expect(not panel.set_active_tool(&"polygon"), "unknown tools should be rejected")
support.expect_equal(panel.get_active_tool(), &"move",
	"a rejected tool should preserve the active state")
```

- [ ] Update `_assert_one_pressed` to traverse `ToolGrid` and count pressed buttons. Only the five
  functional buttons may have `toggle_mode = true`:

```gdscript
func _assert_one_pressed(support, panel: Node, active_name: String) -> void:
	var pressed_count := 0
	var grid := panel.get_node("ToolGrid") as GridContainer
	for child: Node in grid.get_children():
		var button := child as Button
		if button.toggle_mode and button.button_pressed:
			pressed_count += 1
		support.expect_equal(
			button.button_pressed,
			button.name == active_name,
			"%s pressed state should match active tool" % button.name,
		)
	support.expect_equal(pressed_count, 1,
		"ToolPanel should keep exactly one functional tool pressed")
```
- [ ] Run the Godot suite and confirm failures for the missing grid, labels, and signal.

### 2.2 Add original icon assets

- [ ] Create twelve 24 x 24 SVG line icons under `client/ui/icons/tools/`. Use only these project
  colors and drawing rules so the set is visibly coherent and original:

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
  <g fill="none" stroke="#67b7ff" stroke-width="1.8"
     stroke-linecap="round" stroke-linejoin="round">
    <!-- each file contains only its geometry from the table below -->
  </g>
</svg>
```

| File | Exact geometry inside `<g>` |
|---|---|
| `add_box.svg` | `<rect x="5" y="5" width="12" height="12" rx="1"/><path d="M19 13v6M16 16h6"/>` |
| `subtract.svg` | `<rect x="5" y="5" width="12" height="12" rx="1"/><path d="M16 19h6"/>` |
| `lasso.svg` | `<path d="M18 7c3 4 0 9-5 9S4 13 5 9s7-6 13-2Z"/><path d="M13 16c0 3-2 5-5 5"/>` |
| `fill.svg` | `<path d="m7 4 9 9-6 6-6-6 9-9"/><path d="M15 19h6M18 16v6"/>` |
| `erase.svg` | `<path d="m8 5 11 11-5 5H8l-5-5Z"/><path d="m6 14 5 5"/>` |
| `close.svg` | `<path d="M5 12a7 7 0 1 0 2-5"/><path d="M5 3v4h4"/>` |
| `paint.svg` | `<path d="m14 4 6 6-9 9-6-1-1-6Z"/><path d="m6 13 5 5M16 6l2-2"/>` |
| `wipe.svg` | `<path d="M4 17c5-1 6-9 11-9 3 0 5 2 5 5 0 5-6 7-11 7"/><path d="M4 14v6h6"/>` |
| `region_growing.svg` | `<circle cx="8" cy="13" r="3"/><circle cx="14" cy="9" r="3"/><circle cx="16" cy="16" r="4"/>` |
| `live_wire.svg` | `<path d="M4 17c4-10 8 4 16-10"/><circle cx="4" cy="17" r="1.5"/><circle cx="20" cy="7" r="1.5"/>` |
| `selection.svg` | `<path d="m5 3 14 9-7 2-3 7Z"/><path d="m13 14 5 5"/>` |
| `move_resize.svg` | `<path d="M12 3v18M3 12h18M12 3l-3 3M12 3l3 3M21 12l-3-3M21 12l-3 3M12 21l-3-3M12 21l3-3M3 12l3-3M3 12l3 3"/>` |

Remove the XML comment when creating each file. Do not copy imagery from MITK or the guide.

### 2.3 Simplify the scene to one heading and one flat grid

- [ ] Replace `client/ui/tool_panel.tscn` with:

```ini
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://client/ui/tool_panel.gd" id="1_tool_panel"]

[node name="ToolPanel" type="VBoxContainer"]
custom_minimum_size = Vector2(320, 226)
theme_override_constants/separation = 6
script = ExtResource("1_tool_panel")

[node name="Title" type="Label" parent="."]
layout_mode = 2
text = "2D Tools"
horizontal_alignment = 1

[node name="ToolGrid" type="GridContainer" parent="."]
layout_mode = 2
columns = 4
theme_override_constants/h_separation = 4
theme_override_constants/v_separation = 4
```

### 2.4 Implement the single declarative registry

- [ ] Replace `client/ui/tool_panel.gd` with a registry-driven implementation. The registry order is
  the visual order and the only tool inventory:

```gdscript
class_name ToolPanel
extends VBoxContainer

signal tool_requested(tool_id: StringName)
signal unavailable_tool_requested(tool_id: StringName)

const TOOL_DEFINITIONS: Array[Dictionary] = [
	{"id": &"box", "node_name": "Box", "label": "Add Box", "implemented": true,
		"tooltip": "Drag to add a box", "icon": preload("res://client/ui/icons/tools/add_box.svg")},
	{"id": &"subtract", "node_name": "Subtract", "label": "Subtract", "implemented": false,
		"tooltip": "Reserved 2D subtraction tool", "icon": preload("res://client/ui/icons/tools/subtract.svg")},
	{"id": &"lasso", "node_name": "Lasso", "label": "Lasso", "implemented": false,
		"tooltip": "Reserved freehand lasso tool", "icon": preload("res://client/ui/icons/tools/lasso.svg")},
	{"id": &"fill", "node_name": "Fill", "label": "Fill", "implemented": true,
		"tooltip": "Toggle fill on the selected region", "icon": preload("res://client/ui/icons/tools/fill.svg")},
	{"id": &"delete", "node_name": "Delete", "label": "Erase", "implemented": true,
		"tooltip": "Click a region to erase it", "icon": preload("res://client/ui/icons/tools/erase.svg")},
	{"id": &"close", "node_name": "Close", "label": "Close", "implemented": false,
		"tooltip": "Reserved contour-closing tool", "icon": preload("res://client/ui/icons/tools/close.svg")},
	{"id": &"paint", "node_name": "Paint", "label": "Paint", "implemented": false,
		"tooltip": "Reserved brush painting tool", "icon": preload("res://client/ui/icons/tools/paint.svg")},
	{"id": &"wipe", "node_name": "Wipe", "label": "Wipe", "implemented": false,
		"tooltip": "Reserved wipe tool", "icon": preload("res://client/ui/icons/tools/wipe.svg")},
	{"id": &"region_growing", "node_name": "RegionGrowing", "label": "Region Growing",
		"implemented": false, "tooltip": "Reserved region-growing tool",
		"icon": preload("res://client/ui/icons/tools/region_growing.svg")},
	{"id": &"live_wire", "node_name": "LiveWire", "label": "Live Wire", "implemented": false,
		"tooltip": "Reserved live-wire tool", "icon": preload("res://client/ui/icons/tools/live_wire.svg")},
	{"id": &"select", "node_name": "Select", "label": "Selection", "implemented": true,
		"tooltip": "Select a region", "icon": preload("res://client/ui/icons/tools/selection.svg")},
	{"id": &"move", "node_name": "Move", "label": "Move / Resize", "implemented": true,
		"tooltip": "Move or resize the selected region",
		"icon": preload("res://client/ui/icons/tools/move_resize.svg")},
]

@onready var _grid: GridContainer = $ToolGrid

var _buttons: Dictionary = {}
var _implemented: Dictionary = {}
var _active_tool: StringName = &"select"
var _button_group := ButtonGroup.new()


func _ready() -> void:
	for definition: Dictionary in TOOL_DEFINITIONS:
		var tool_id: StringName = definition["id"]
		var implemented: bool = definition["implemented"]
		var button := Button.new()
		button.name = definition["node_name"]
		button.text = definition["label"]
		button.tooltip_text = definition["tooltip"]
		button.icon = definition["icon"]
		button.custom_minimum_size = Vector2(76, 62)
		button.expand_icon = false
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.toggle_mode = implemented
		if implemented:
			button.button_group = _button_group
		_buttons[tool_id] = button
		_implemented[tool_id] = implemented
		_grid.add_child(button)
		button.pressed.connect(_on_tool_pressed.bind(tool_id))
	_sync_pressed_state()


func set_active_tool(tool_id: StringName) -> bool:
	if not _implemented.get(tool_id, false):
		return false
	_active_tool = tool_id
	_sync_pressed_state()
	return true


func get_active_tool() -> StringName:
	return _active_tool


func _on_tool_pressed(tool_id: StringName) -> void:
	if not _implemented.get(tool_id, false):
		_sync_pressed_state()
		unavailable_tool_requested.emit(tool_id)
		return
	if set_active_tool(tool_id):
		tool_requested.emit(tool_id)


func _sync_pressed_state() -> void:
	if not is_node_ready():
		return
	for tool_id: StringName in _buttons:
		var button := _buttons[tool_id] as Button
		button.button_pressed = _implemented[tool_id] and tool_id == _active_tool
```

### 2.5 Verify and commit

- [ ] Run the Godot suite and confirm all existing functional tool tests still pass.
- [ ] Run `git diff --check`.
- [ ] Confirm the seven reserved clicks never emit `tool_requested`.
- [ ] Commit:

```bash
git add client/ui/tool_panel.gd client/ui/tool_panel.tscn client/ui/icons/tools \
  tests/godot/test_tool_panel.gd
git commit -m "feat: add flat MITK-style 2D tool palette"
```

---

## Task 3: Compose the approved resizable three-column workspace

**Files:**

- Modify: `client/app/main.tscn`
- Modify: `client/app/main.gd`
- Modify: `tests/godot/test_frontend_structure.gd`
- Modify: `tests/godot/test_playback.gd`
- Modify: `tests/godot/test_main_boundaries.gd`

### 3.1 Write the failing structure test

- [ ] Replace old workspace paths in `tests/godot/test_frontend_structure.gd` with these required
  paths:

```gdscript
"MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer",
"MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport",
"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/InspectorScroll/InspectorPanel",
"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/Separator",
"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel",
```

- [ ] Add composition assertions:

```gdscript
var workspace := main.get_node("MainVBox/WorkspaceSplit") as HSplitContainer
var content := main.get_node("MainVBox/WorkspaceSplit/ContentSplit") as HSplitContainer
var explorer_container := main.get_node(
	"MainVBox/WorkspaceSplit/DatasetExplorerContainer"
) as PanelContainer
var right_container := main.get_node(
	"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer"
) as PanelContainer
var inspector_scroll := main.get_node(
	"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/InspectorScroll"
) as ScrollContainer
var tool_panel := main.get_node(
	"MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel"
)
support.expect(workspace != null and content != null,
	"workspace should use nested resizable split containers")
support.expect(explorer_container.custom_minimum_size.x >= 220.0,
	"dataset explorer should retain its approved minimum width")
support.expect(right_container.custom_minimum_size.x >= 320.0,
	"right sidebar should retain its approved minimum width")
support.expect(inspector_scroll.size_flags_vertical == Control.SIZE_EXPAND_FILL,
	"inspector should scroll and yield fixed space to the tool grid")
support.expect(tool_panel.get_parent().name == "RightSidebar",
	"ToolPanel should sit below the right inspector")
support.expect(main.get_node_or_null("MainVBox/Workspace/ToolPanel") == null,
	"the obsolete left edit strip should be absent")
```

- [ ] Keep the toolbar, timeline, status, source dialog, plugin discovery, and real component API
  assertions unchanged apart from their new node paths.
- [ ] Run the Godot suite and confirm it fails on the old scene composition.

### 3.2 Rewrite only the workspace composition in main.tscn

- [ ] Add the DatasetExplorer external resource and increase `load_steps` by one:

```ini
[ext_resource type="PackedScene" path="res://client/ui/dataset_explorer.tscn" id="6_explorer"]
```

- [ ] Replace only the current `Workspace` subtree with:

```ini
[node name="WorkspaceSplit" type="HSplitContainer" parent="MainVBox"]
layout_mode = 2
size_flags_vertical = 3

[node name="DatasetExplorerContainer" type="PanelContainer" parent="MainVBox/WorkspaceSplit"]
custom_minimum_size = Vector2(220, 0)
layout_mode = 2

[node name="DatasetExplorer" parent="MainVBox/WorkspaceSplit/DatasetExplorerContainer" instance=ExtResource("6_explorer")]
layout_mode = 2

[node name="ContentSplit" type="HSplitContainer" parent="MainVBox/WorkspaceSplit"]
layout_mode = 2
size_flags_horizontal = 3

[node name="ViewportPanel" type="PanelContainer" parent="MainVBox/WorkspaceSplit/ContentSplit"]
custom_minimum_size = Vector2(500, 300)
layout_mode = 2
size_flags_horizontal = 3

[node name="AnnotationViewport" parent="MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel" instance=ExtResource("2_viewport")]
layout_mode = 2

[node name="RightSidebarContainer" type="PanelContainer" parent="MainVBox/WorkspaceSplit/ContentSplit"]
custom_minimum_size = Vector2(320, 0)
layout_mode = 2

[node name="RightSidebar" type="VBoxContainer" parent="MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer"]
layout_mode = 2

[node name="InspectorScroll" type="ScrollContainer" parent="MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar"]
layout_mode = 2
size_flags_vertical = 3
horizontal_scroll_mode = 0

[node name="InspectorPanel" parent="MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/InspectorScroll" instance=ExtResource("3_inspector")]
layout_mode = 2
size_flags_horizontal = 3

[node name="Separator" type="HSeparator" parent="MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar"]
layout_mode = 2

[node name="ToolPanel" parent="MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar" instance=ExtResource("5_tools")]
layout_mode = 2
```

Do not modify `TopToolbar`, `TimelinePanel`, `StatusBar`, `SourceDialog`, or `PlaybackTimer` in this
step.

### 3.3 Update node paths without changing behavior

- [ ] Replace the three old `AnnotationMain` paths and add the explorer reference:

```gdscript
@onready var _dataset_explorer = $MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer
@onready var _viewport = $MainVBox/WorkspaceSplit/ContentSplit/ViewportPanel/AnnotationViewport
@onready var _inspector = $MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/InspectorScroll/InspectorPanel
@onready var _tool_panel = $MainVBox/WorkspaceSplit/ContentSplit/RightSidebarContainer/RightSidebar/ToolPanel
```

- [ ] Mechanically replace old viewport, inspector, and tool-panel paths in
  `tests/godot/test_playback.gd` and `tests/godot/test_main_boundaries.gd`. Use this audit command
  and require no output:

```bash
rg -n 'MainVBox/Workspace/' client/app tests/godot
```

- [ ] Because Task 2 nests the generated controls under `ToolGrid`, replace existing direct child
  lookups such as `tool_panel.get_node("Move")`, `tool_panel.get_node("Box")`, and
  `tool_panel.get_node("Select")` with `ToolGrid/Move`, `ToolGrid/Box`, and `ToolGrid/Select`.
  Require this audit to return no direct-child matches:

```bash
rg -n 'tool_panel\.get_node\("(Move|Box|Fill|Delete|Select)"\)' tests/godot
```

- [ ] Do not wire explorer signals or build its model in this task; Task 4 owns coordination.

### 3.4 Verify and commit

- [ ] Run the Godot suite and confirm main scene instantiation and every existing edit/playback test
  passes with only node-path changes.
- [ ] Run `git diff --check`.
- [ ] Commit:

```bash
git add client/app/main.tscn client/app/main.gd tests/godot/test_frontend_structure.gd \
  tests/godot/test_playback.gd tests/godot/test_main_boundaries.gd
git commit -m "refactor: compose three-column annotation workspace"
```

---

## Task 4: Coordinate explorer navigation and reserved-tool feedback in AnnotationMain

**Files:**

- Modify: `client/app/main.gd`
- Modify: `tests/godot/test_playback.gd`
- Modify: `tests/godot/test_main_boundaries.gd`
- Modify: `tests/godot/fixtures/integration_plugins/counting_source.gd`

### 4.1 Write failing main integration assertions

- [ ] Extend the successful normalized-source section of `test_playback.gd`:

```gdscript
var explorer = main.get_node(
	"MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer"
)
support.expect_equal(explorer.get("_view_model")["display_name"], "valid",
	"successful open should populate the accepted dataset")
support.expect_equal(explorer.get("_view_model")["frames"].size(), 120,
	"explorer should contain every accepted manifest frame")
support.expect_equal(explorer.get_selected_frame(), 0,
	"successful open should highlight frame zero")

explorer.frame_requested.emit(5)
support.expect_equal(main.get_current_frame(), 5,
	"explorer navigation should seek through AnnotationMain")
support.expect_equal(explorer.get_selected_frame(), 5,
	"explorer highlight should agree with the accepted frame")
support.expect(main.seek(7), "direct seek should succeed")
support.expect_equal(explorer.get_selected_frame(), 7,
	"direct seek should update the explorer without a second request")
```

- [ ] Before an existing failed replacement attempt, capture the explorer model; after the failure,
  assert exact preservation:

```gdscript
var explorer_before: Dictionary = explorer.get("_view_model").duplicate(true)
var selected_before: int = explorer.get_selected_frame()
var failed_root := _make_source(support, "corrupt-replacement", 1, 24.0)
_write_text(failed_root.path_join("frames/frame_000000.png"), "not image data")
var replacement_errors: PackedStringArray = main.open_source(failed_root)
support.expect(not replacement_errors.is_empty(),
	"replacement with a corrupt first texture should fail")
support.expect_equal(explorer.get("_view_model"), explorer_before,
	"failed source replacement should preserve the explorer tree")
support.expect_equal(explorer.get_selected_frame(), selected_before,
	"failed source replacement should preserve explorer selection")
```

- [ ] Extend the existing direct-image test:

```gdscript
var image_model: Dictionary = explorer.get("_view_model")
support.expect_equal(image_model["frames"].size(), 1,
	"a standalone image should expose one frame")
support.expect_equal(image_model["display_name"], image_path.get_file(),
	"a standalone image should identify the real opened file")
support.expect_equal(image_model["frames"][0]["label"], image_path.get_file(),
	"a standalone image should show its real file name")
support.expect_equal(image_model["artifacts"], [],
	"a standalone image should not invent disk metadata")
```

- [ ] Add reserved-tool behavior after a valid source is open:

```gdscript
var store = main.get("_store")
var history = main.get("_history")
var record_before: Dictionary = store.get_corrected_record(main.get_current_frame())
var active_before: StringName = tool_panel.get_active_tool()
var can_undo_before: bool = history.can_undo()
(tool_panel.get_node("ToolGrid/Subtract") as Button).pressed.emit()
support.expect_equal(main.get_node("MainVBox/StatusBar").text, "待开发",
	"reserved tools should produce the exact approved status")
support.expect_equal(tool_panel.get_active_tool(), active_before,
	"reserved tools should preserve active edit mode")
support.expect_equal(store.get_corrected_record(main.get_current_frame()), record_before,
	"reserved tools should not mutate annotation data")
support.expect_equal(history.can_undo(), can_undo_before,
	"reserved tools should not create history")
```

- [ ] In `_test_source_boundary_validation` in `test_main_boundaries.gd`, add this immediately after
  the baseline source opens:

```gdscript
var explorer = main.get_node(
	"MainVBox/WorkspaceSplit/DatasetExplorerContainer/DatasetExplorer"
)
var accepted_model: Dictionary = explorer.get("_view_model").duplicate(true)
explorer.populate({"display_name": "broken"})
support.expect("Dataset explorer" in _status(main),
	"invalid explorer data should produce a user-facing status")
support.expect(_status(main).length() <= 180,
	"invalid explorer data should produce a bounded status")
support.expect_equal(explorer.get("_view_model"), accepted_model,
	"invalid explorer data should preserve the accepted tree")
```
- [ ] Run the Godot suite and confirm these assertions fail before wiring.

### 4.2 Build the view model from the already staged source data

- [ ] Add this helper to `client/app/main.gd` without reading textures or annotations:

```gdscript
func _build_dataset_explorer_view_model(path: String, manifest: Dictionary) -> Dictionary:
	var absolute := ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
	var is_directory := DirAccess.dir_exists_absolute(absolute)
	var frames: Array[Dictionary] = []
	var frame_values: Variant = manifest.get("frames", [])
	if frame_values is Array:
		for position in range(frame_values.size()):
			var entry_value: Variant = frame_values[position]
			if not entry_value is Dictionary:
				continue
			var relative := str(entry_value.get("image_path", ""))
			frames.append({
				"index": position,
				"label": relative,
				"path": absolute.path_join(relative) if is_directory else absolute,
			})
	var artifacts: Array[Dictionary] = []
	if is_directory:
		var model_version := str(manifest.get("model_version", "none"))
		var artifact_labels := ["manifest.json"]
		if model_version == "model_output_v1":
			artifact_labels.append("model_output_v1.jsonl")
		for label: String in artifact_labels:
			var artifact_path := absolute.path_join(label)
			if FileAccess.file_exists(artifact_path):
				artifacts.append({"label": label, "path": artifact_path})
	var display_name := str(manifest.get("dataset_id", absolute.get_file()))
	if not is_directory:
		display_name = absolute.get_file()
	return {
		"display_name": display_name,
		"source_path": absolute,
		"frames": frames,
		"artifacts": artifacts,
	}
```

This helper uses manifest labels and real filesystem existence only. It must not call
`load_texture`, access `AnnotationStore`, or own source validation.

### 4.3 Populate only after a successful source commit

- [ ] Immediately before the existing commit boundary (`pause()`), build a local candidate:

```gdscript
var candidate_explorer_view_model := _build_dataset_explorer_view_model(path, candidate_manifest)
```

- [ ] On the successful path, after all current source/store/edit/renderer state is assigned and
  after `StatusBar` receives the loaded message, add:

```gdscript
_dataset_explorer.populate(candidate_explorer_view_model)
_dataset_explorer.select_frame(0)
```

Do not add any explorer call to an error return path. Placing `populate` after the loaded status
also guarantees that an unexpected view-model rejection becomes the final visible status instead
of being overwritten by `Loaded ...`.

- [ ] After the existing successful `set_frame` state commit, add:

```gdscript
_dataset_explorer.select_frame(index)
```

Do not update the explorer before texture, record, and entry validation succeeds.

### 4.4 Wire the two new intent boundaries

- [ ] Add these handlers:

```gdscript
func _on_explorer_frame_requested(index: int) -> void:
	_on_timeline_frame_requested(index)


func _on_unavailable_tool_requested(_tool_id: StringName) -> void:
	_set_status("待开发")


func _on_explorer_view_model_rejected(message: String) -> void:
	_set_status(message)
```

- [ ] Add these connections in `_connect_ui()`:

```gdscript
_dataset_explorer.frame_requested.connect(_on_explorer_frame_requested)
_dataset_explorer.view_model_rejected.connect(_on_explorer_view_model_rejected)
_tool_panel.unavailable_tool_requested.connect(_on_unavailable_tool_requested)
```

- [ ] Update only the user-facing names in `_tool_display_name`:

```gdscript
&"select":
	return "Selection"
&"move":
	return "Move / Resize"
&"box":
	return "Add Box"
&"fill":
	return "Fill"
&"delete":
	return "Erase"
```

Internal IDs remain unchanged.

### 4.5 Keep the source test double manifest-shaped

The existing `counting_source.gd` is a deliberately small source test double. Its successful
manifest currently omits `dataset_id` and `frames`, even though production sources provide them.
That would cause an unrelated explorer rejection during source-boundary tests.

- [ ] In `get_manifest()`, replace the successful return with a complete lightweight manifest:

```gdscript
	var frames: Array[Dictionary] = []
	for index in range(count):
		frames.append({
			"frame": index,
			"time_s": 1.25 + float(index),
			"image_path": "fixture_%06d.png" % index,
		})
	return {
		"dataset_id": "counting-source",
		"frame_count": count,
		"nominal_fps": fps,
		"frames": frames,
	}
```

Keep every existing mode, return type, counter, texture, record, and malformed-entry behavior
unchanged. This modifies only the test double, not a production Source plugin or API.

### 4.6 Verify and commit

- [ ] Run the Godot suite. Confirm normalized source, direct image, invalid replacement,
  navigation, edit history, keyboard handling, and reserved-tool assertions pass.
- [ ] Run `git diff --check`.
- [ ] Confirm with `git diff -- client/app/main.gd` that no plugin API or edit command changed.
- [ ] Commit:

```bash
git add client/app/main.gd tests/godot/test_playback.gd tests/godot/test_main_boundaries.gd \
  tests/godot/fixtures/integration_plugins/counting_source.gd
git commit -m "feat: coordinate dataset explorer and reserved tools"
```

---

## Task 5: Reconcile documentation and complete acceptance

**Files:**

- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/requirements-traceability.md`
- Verify: all files changed by Tasks 1–4

### 5.1 Audit scope before touching documentation

- [ ] In the isolated implementation worktree, reread the current versions of the three listed
  documents. Do not copy or replace files from the dirty originating checkout.
- [ ] Search for stale layout descriptions:

```bash
rg -n 'left tool|ToolPanel|Select.*Move.*Box|Workspace/ToolPanel|InspectorPanelContainer' \
  README.md docs/architecture.md docs/requirements-traceability.md
```

- [ ] Update only statements affected by this approved design:
  - left panel is the active-dataset explorer, not a general file manager;
  - center is the real annotation viewport;
  - right side is scrollable region properties above one flat twelve-slot 2D palette;
  - only Add Box, Fill, Erase, Selection, and Move / Resize are functional;
  - seven named reserved controls display `待开发` and are not completed features;
  - source/render/edit/feedback interfaces and Part 1 contracts remain unchanged.
- [ ] Explicitly state that this change-specific design supersedes only the older left-tool
  placement in the earlier plan. Do not rewrite assignment requirements or claim extra scope.

### 5.2 Run the complete automated regression gates

- [ ] Godot:

```bash
/home/wang/下载/Godot_v4.7.2-stable_linux.x86_64 \
  --headless --path . --script res://tests/godot/test_runner.gd
```

Expected final line: `PASS: complete Godot test suite` and exit code 0. Robustness fixtures may
log expected corrupt-image messages, but they must not produce a failing exit.

- [ ] Python:

```bash
PATH="$PWD/.tools/ffmpeg/bin:$PATH" .venv/bin/python -m pytest tests/python -q
```

Expected: all existing Python tests pass; no Python implementation file changes are required.

- [ ] Static repository gates:

```bash
git diff --check
rg -n 'MainVBox/Workspace/' client/app tests/godot
git status --short
```

Expected: no old workspace path matches, no whitespace errors, and only task-owned files are
modified in the isolated worktree.

### 5.3 Perform the manual 1280 x 800 reviewer check

- [ ] Launch the project at 1280 x 800 and open a standalone PNG/JPG/JPEG. Verify:
  - the image remains visible in the center;
  - the left tree shows the real image and one frame, without invented metadata files;
  - the right inspector scrolls;
  - all twelve tool labels and icons are readable;
  - the 2D palette remains fixed below the inspector.
- [ ] Open a normalized dataset. Verify:
  - `Frames (<count>)` matches the accepted manifest;
  - 只显示真实存在的 `manifest.json` 和版本化 `model_output_v1.jsonl`；
  - clicking a frame updates image, timeline, time label, and highlight once;
  - timeline, previous/next, playback, and direct seek update the same highlight.
- [ ] Select a functional tool and click each reserved tool. Verify every click shows exactly
  `待开发` while active tool, selection, annotation content, and undo/redo state stay unchanged.
- [ ] Attempt a known invalid replacement source. Verify explorer, image, annotations, selected
  frame, and history all remain unchanged.
- [ ] Resize both split handles. Verify the center remains usable and no docking or file-management
  behavior appears.

### 5.4 Record honest evidence and commit documentation

- [ ] In `docs/requirements-traceability.md`, record the exact Godot/Python results and the manual
  observations. Mark the seven reserved tools as unavailable controls, never as implemented tools.
- [ ] Run `git diff --check` again.
- [ ] Commit only the reconciled documentation:

```bash
git add README.md docs/architecture.md docs/requirements-traceability.md
git commit -m "docs: record frontend layout and verification"
```

- [ ] Inspect `git log --oneline -5` and `git status --short`. The implementation worktree must be
  clean and show five focused feature commits after the approved design commits.
- [ ] Use `superpowers:verification-before-completion` before reporting completion or proposing a
  merge/push.

---

## Final Scope Audit

Before integration, require all answers below to be `yes`:

- [ ] Does the left pane show only the accepted active dataset?
- [ ] Does the central viewport reuse the existing renderer and transforms unchanged?
- [ ] Are region properties above the flat four-column tool grid on the right?
- [ ] Are all twelve labels, stable IDs, icons, tooltips, and positions present?
- [ ] Are exactly five tools routed to the existing Edit plugin?
- [ ] Do exactly seven tools route only to the `待开发` status boundary?
- [ ] Does failed source replacement preserve the entire active UI and domain state?
- [ ] Do explorer-driven and programmatic navigation avoid feedback loops?
- [ ] Are plugin API v1, schemas, store, history, renderer, source plugins, and Python code unchanged?
- [ ] Do the Godot, Python, static, and manual acceptance gates all pass with recorded evidence?
