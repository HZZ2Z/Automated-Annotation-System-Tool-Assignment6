class_name ToolPanel
extends VBoxContainer

signal tool_requested(tool_id: StringName)

const TOOL_IDS: Array[StringName] = [
	&"select",
	&"move",
	&"box",
	&"fill",
	&"delete",
]

@onready var _buttons: Dictionary = {
	&"select": $Select,
	&"move": $Move,
	&"box": $Box,
	&"fill": $Fill,
	&"delete": $Delete,
}

var _active_tool: StringName = &"select"


func _ready() -> void:
	for tool_id: StringName in TOOL_IDS:
		var button := _buttons[tool_id] as Button
		button.pressed.connect(_on_tool_pressed.bind(tool_id))
	_sync_pressed_state()


func set_active_tool(tool_id: StringName) -> bool:
	if tool_id not in TOOL_IDS:
		return false
	_active_tool = tool_id
	_sync_pressed_state()
	return true


func get_active_tool() -> StringName:
	return _active_tool


func _on_tool_pressed(tool_id: StringName) -> void:
	if set_active_tool(tool_id):
		tool_requested.emit(tool_id)


func _sync_pressed_state() -> void:
	if not is_node_ready():
		return
	for tool_id: StringName in TOOL_IDS:
		(_buttons[tool_id] as Button).button_pressed = tool_id == _active_tool
