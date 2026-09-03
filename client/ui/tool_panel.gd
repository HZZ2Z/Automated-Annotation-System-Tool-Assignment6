class_name ToolPanel
extends VBoxContainer

signal tool_requested(tool_id: StringName)
signal unavailable_tool_requested(tool_id: StringName)

const COMPACT_ICON_MAX_WIDTH := 16
const COMPACT_FONT_SIZE := 11
const REQUIRED_FIELDS := ["id", "node_name", "label", "implemented", "tooltip", "icon_path"]

@onready var _grid: GridContainer = $ToolGrid

var _buttons: Dictionary = {}
var _implemented: Dictionary = {}
var _active_tool: StringName = &"select"
var _button_group := ButtonGroup.new()
var _definitions: Array[Dictionary] = []


func _ready() -> void:
	pass


func validate_tools(definitions: Array[Dictionary]) -> PackedStringArray:
	var errors := PackedStringArray()
	_prepare_tools(definitions, errors)
	return errors


func configure_tools(definitions: Array[Dictionary]) -> PackedStringArray:
	var errors := PackedStringArray()
	var prepared := _prepare_tools(definitions, errors)
	if not errors.is_empty():
		return errors
	for child: Node in _grid.get_children():
		_grid.remove_child(child)
		child.free()
	_buttons.clear()
	_implemented.clear()
	_definitions = definitions.duplicate(true)
	_button_group = ButtonGroup.new()
	var default_tool := StringName()
	for prepared_value: Variant in prepared:
		var prepared_entry: Dictionary = prepared_value
		var definition: Dictionary = prepared_entry["definition"]
		var tool_id: StringName = definition["id"]
		var implemented: bool = definition["implemented"]
		var button := Button.new()
		button.name = definition["node_name"]
		button.text = str(definition.get("presentation_text", definition["label"]))
		button.tooltip_text = definition["tooltip"]
		button.icon = prepared_entry["icon"]
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
		if implemented and (default_tool.is_empty() or bool(definition.get("default", false))):
			default_tool = tool_id
	_active_tool = default_tool
	_sync_pressed_state()
	return errors


func get_tool_label(tool_id: StringName) -> String:
	for definition: Dictionary in _definitions:
		if StringName(definition["id"]) == tool_id:
			return str(definition["label"])
	return str(tool_id)


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


func _prepare_tools(definitions: Array[Dictionary], errors: PackedStringArray) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if definitions.is_empty():
		errors.append("tools: expected a non-empty descriptor array")
		return result
	var ids := {}
	var node_names := {}
	var default_count := 0
	for index in range(definitions.size()):
		var definition: Dictionary = definitions[index]
		for field: String in REQUIRED_FIELDS:
			if not definition.has(field):
				errors.append("tools.%d.%s: required field missing" % [index, field])
		var id_value: Variant = definition.get("id")
		var node_value: Variant = definition.get("node_name")
		for field: String in ["label", "tooltip", "icon_path"]:
			var value: Variant = definition.get(field)
			if typeof(value) != TYPE_STRING or String(value).is_empty():
				errors.append("tools.%d.%s: expected non-empty String" % [index, field])
		if (typeof(id_value) != TYPE_STRING and typeof(id_value) != TYPE_STRING_NAME) or String(id_value).is_empty():
			errors.append("tools.%d.id: expected non-empty identifier" % index)
		elif ids.has(StringName(id_value)):
			errors.append("tools.%d.id: duplicate %s" % [index, id_value])
		else:
			ids[StringName(id_value)] = true
		if typeof(node_value) != TYPE_STRING or String(node_value).is_empty() or not String(node_value).is_valid_identifier():
			errors.append("tools.%d.node_name: expected valid node identifier" % index)
		elif node_names.has(node_value):
			errors.append("tools.%d.node_name: duplicate %s" % [index, node_value])
		else:
			node_names[node_value] = true
		if typeof(definition.get("implemented")) != TYPE_BOOL:
			errors.append("tools.%d.implemented: expected bool" % index)
		if bool(definition.get("default", false)):
			default_count += 1
			if not bool(definition.get("implemented", false)):
				errors.append("tools.%d.default: default tool must be implemented" % index)
		var icon: Variant
		var icon_path := str(definition.get("icon_path", ""))
		if not icon_path.begins_with("res://"):
			errors.append("tools.%d.icon_path: expected res:// path" % index)
		else:
			icon = ResourceLoader.load(icon_path)
			if not icon is Texture2D:
				errors.append("tools.%d.icon_path: expected Texture2D resource" % index)
		result.append({"definition": definition.duplicate(true), "icon": icon})
	if default_count > 1:
		errors.append("tools: expected at most one default tool")
	return result
