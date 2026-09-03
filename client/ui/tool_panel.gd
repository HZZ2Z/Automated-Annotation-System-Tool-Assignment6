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
const TOOL_PRESENTATION_TEXT := {
	&"box": "Add\nBox",
	&"region_growing": "Region\nGrowing",
	&"live_wire": "Live\nWire",
	&"move": "Move /\nResize",
}
const COMPACT_ICON_MAX_WIDTH := 16
const COMPACT_FONT_SIZE := 11

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
		button.text = str(TOOL_PRESENTATION_TEXT.get(tool_id, definition["label"]))
		button.tooltip_text = definition["tooltip"]
		button.icon = definition["icon"]
		button.custom_minimum_size = Vector2(76, 62)
		button.expand_icon = false
		button.autowrap_mode = TextServer.AUTOWRAP_OFF
		button.add_theme_constant_override("icon_max_width", COMPACT_ICON_MAX_WIDTH)
		button.add_theme_font_size_override("font_size", COMPACT_FONT_SIZE)
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
