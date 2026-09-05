class_name ToolPanel
extends VBoxContainer

signal tool_requested(tool_id: StringName)
signal unavailable_tool_requested(tool_id: StringName)
signal tool_option_changed(tool_id: StringName, option_id: StringName, value: Variant)

const COMPACT_ICON_MAX_WIDTH := 16
const COMPACT_FONT_SIZE := 11
const REQUIRED_FIELDS := ["id", "node_name", "label", "implemented", "tooltip", "icon_path"]

@onready var _grid: GridContainer = $ToolGrid
@onready var _option_row: Control = $OptionRow
@onready var _option_label: Label = $OptionRow/Label
@onready var _option_value: SpinBox = $OptionRow/Value

var _buttons: Dictionary = {}
var _implemented: Dictionary = {}
var _active_tool: StringName = &"select"
var _button_group := ButtonGroup.new()
var _definitions: Array[Dictionary] = []
var _option_values: Dictionary = {}
var _active_option: Dictionary = {}
var _syncing_option := false


func _ready() -> void:
	_option_value.value_changed.connect(_on_option_value_changed)
	_option_row.visible = false


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
	_option_values.clear()
	_active_option.clear()
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
		for option: Dictionary in definition.get("options", []):
			var shared_key := StringName(option.get("shared_key", option.get("id", &"")))
			if not _option_values.has(shared_key):
				_option_values[shared_key] = option.get("default")
	_active_tool = default_tool
	_sync_pressed_state()
	_sync_active_option()
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
	_sync_active_option()
	return true


func get_active_tool() -> StringName:
	return _active_tool


func accept_tool_option(tool_id: StringName, option_id: StringName, value: Variant) -> bool:
	var option := _find_option(tool_id, option_id)
	if option.is_empty() or not _valid_option_value(option, value):
		return false
	var shared_key := StringName(option.get("shared_key", option.get("id", &"")))
	_option_values[shared_key] = float(value)
	if not _active_option.is_empty():
		var active_shared_key := StringName(_active_option.get("shared_key", _active_option.get("id", &"")))
		if active_shared_key == shared_key:
			_restore_active_option_value()
	return true


func restore_tool_option(tool_id: StringName, option_id: StringName) -> bool:
	var option := _find_option(tool_id, option_id)
	if option.is_empty():
		return false
	var shared_key := StringName(option.get("shared_key", option.get("id", &"")))
	if not _active_option.is_empty():
		var active_shared_key := StringName(_active_option.get("shared_key", _active_option.get("id", &"")))
		if active_shared_key == shared_key:
			_restore_active_option_value()
	return true


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


func _sync_active_option() -> void:
	if not is_node_ready():
		return
	_active_option.clear()
	for definition: Dictionary in _definitions:
		if StringName(definition.get("id", &"")) != _active_tool:
			continue
		var options: Variant = definition.get("options", [])
		if options is Array and not options.is_empty() and options[0] is Dictionary:
			_active_option = (options[0] as Dictionary).duplicate(true)
		break
	_option_row.visible = not _active_option.is_empty()
	if _active_option.is_empty():
		return
	_syncing_option = true
	_option_label.text = str(_active_option.get("label", ""))
	_option_value.min_value = float(_active_option.get("min", 0.0))
	_option_value.max_value = float(_active_option.get("max", 0.0))
	_option_value.step = float(_active_option.get("step", 1.0))
	var shared_key := StringName(_active_option.get("shared_key", _active_option.get("id", &"")))
	_option_value.value = float(_option_values.get(shared_key, _active_option.get("default", 0.0)))
	_syncing_option = false


func _on_option_value_changed(value: float) -> void:
	if _syncing_option or _active_option.is_empty():
		return
	if not _valid_option_value(_active_option, value):
		_restore_active_option_value()
		return
	tool_option_changed.emit(_active_tool, StringName(_active_option.get("id", &"")), value)
	# Signals are synchronous.  The owner may accept during the callback; either
	# way the widget is restored from the last accepted shared value here.
	_restore_active_option_value()


func _restore_active_option_value() -> void:
	if _active_option.is_empty():
		return
	var shared_key := StringName(_active_option.get("shared_key", _active_option.get("id", &"")))
	_syncing_option = true
	_option_value.value = float(_option_values.get(shared_key, _active_option.get("default", 0.0)))
	_syncing_option = false


func _find_option(tool_id: StringName, option_id: StringName) -> Dictionary:
	for definition: Dictionary in _definitions:
		if StringName(definition.get("id", &"")) != tool_id:
			continue
		var options: Variant = definition.get("options", [])
		if options is Array:
			for value: Variant in options:
				if value is Dictionary and StringName(value.get("id", &"")) == option_id:
					return (value as Dictionary).duplicate(true)
	return {}


func _valid_option_value(option: Dictionary, value: Variant) -> bool:
	if not _is_finite_number(value):
		return false
	var min_value := float(option.get("min", 0.0))
	var max_value := float(option.get("max", 0.0))
	return float(value) >= min_value and float(value) <= max_value


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
		var options: Variant = definition.get("options", [])
		if not options is Array:
			errors.append("tools.%d.options: expected Array" % index)
		else:
			for option_index in range(options.size()):
				var option: Variant = options[option_index]
				if not option is Dictionary:
					errors.append("tools.%d.options.%d: expected Dictionary" % [index, option_index])
					continue
				var option_id: Variant = option.get("id")
				var option_label: Variant = option.get("label")
				if (typeof(option_id) != TYPE_STRING and typeof(option_id) != TYPE_STRING_NAME) or String(option_id).is_empty():
					errors.append("tools.%d.options.%d.id: expected non-empty identifier" % [index, option_index])
				if typeof(option_label) != TYPE_STRING or String(option_label).is_empty():
					errors.append("tools.%d.options.%d.label: expected non-empty String" % [index, option_index])
				if StringName(option.get("kind", &"")) != &"float_range":
					errors.append("tools.%d.options.%d.kind: expected float_range" % [index, option_index])
				var min_value: Variant = option.get("min")
				var max_value: Variant = option.get("max")
				var step_value: Variant = option.get("step")
				var default_value: Variant = option.get("default")
				if not _is_finite_number(min_value) or not _is_finite_number(max_value) \
						or not _is_finite_number(step_value) or not _is_finite_number(default_value) \
						or float(min_value) > float(max_value) or float(step_value) <= 0.0 \
						or float(default_value) < float(min_value) or float(default_value) > float(max_value):
					errors.append("tools.%d.options.%d: invalid finite float range" % [index, option_index])
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


func _is_finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
