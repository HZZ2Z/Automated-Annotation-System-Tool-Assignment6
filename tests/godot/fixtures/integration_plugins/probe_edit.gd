extends RefCounted

static var mode := "success"
static var activation_count := 0
static var deactivation_count := 0
static var last_activation_frame := -999
static var last_activation_selection := "unset"
static var class_request_count := 0
static var cancel_pending_count := 0
const CLASS_REQUEST_TOKEN := 7301

var transient_preview := false
var cancel_signal_count := 0
var _viewport: Variant
var _connected := false
var _active := false
var _active_tool: StringName = &"select"
var _saved_frame_getter := Callable()
var _saved_selection_getter := Callable()
var _saved_selection_setter := Callable()
var _saved_class_request := Callable()
var _saved_edit_state_changed := Callable()
var _hostile_viewport_lifecycle := false
var _pending_class_token := -1


static func reset(next_mode: String = "success") -> void:
	mode = next_mode
	activation_count = 0
	deactivation_count = 0
	last_activation_frame = -999
	last_activation_selection = "unset"
	class_request_count = 0
	cancel_pending_count = 0


func get_tool_descriptors() -> Array[Dictionary]:
	return [{
		"id": &"select",
		"node_name": "Select",
		"label": "Selection",
		"implemented": true,
		"default": true,
		"tooltip": "Fixture selection",
		"icon_path": "res://client/ui/icons/tools/selection.svg",
	}]


func invoke(action_id: StringName, _payload: Dictionary = {}) -> PackedStringArray:
	if action_id == &"begin_add_box":
		begin_add_box()
		return PackedStringArray()
	if action_id == &"delete_selected":
		return delete_selected()
	if action_id == &"cancel_pending_region":
		if int(_payload.get("candidate_token", -1)) != _pending_class_token:
			return PackedStringArray(["fixture pending token mismatch"])
		_pending_class_token = -1
		cancel_pending_count += 1
		if _saved_edit_state_changed.is_valid():
			_saved_edit_state_changed.call({
				"phase": &"idle",
				"navigation_blocked": false,
				"message": "",
			})
		return PackedStringArray()
	return PackedStringArray()


func activate(context: Dictionary) -> PackedStringArray:
	activation_count += 1
	if context.is_empty():
		return PackedStringArray(["fixture does not define empty-context teardown"])
	_saved_frame_getter = context.get("get_current_frame")
	_saved_selection_getter = context.get("get_selected_region")
	_saved_selection_setter = context.get("set_selected_region")
	_saved_class_request = context.get("request_class_assignment")
	_saved_edit_state_changed = context.get("edit_state_changed")
	last_activation_frame = int(_saved_frame_getter.call())
	last_activation_selection = str(_saved_selection_getter.call())
	_saved_selection_setter.call("candidate-staged-selection")
	_viewport = context.get("viewport")
	if _viewport != null and _viewport.has_signal("edit_cancel_requested"):
		_viewport.edit_cancel_requested.connect(_on_cancel_signal)
		_connected = true
	_hostile_viewport_lifecycle = mode in [
		"fail_after_hostile_viewport",
		"success_with_hostile_viewport",
		"fail_after_hostile_viewport_and_class_request",
		"success_with_hostile_viewport_and_class_request",
	]
	if _hostile_viewport_lifecycle:
		_mutate_saved_viewport("activate")
	if mode in [
		"fail_after_hostile_viewport_and_class_request",
		"success_with_hostile_viewport_and_class_request",
	]:
		_pending_class_token = CLASS_REQUEST_TOKEN
		class_request_count += 1
		_saved_edit_state_changed.call({
			"phase": &"awaiting_class",
			"navigation_blocked": true,
			"message": "Assign class to fixture candidate",
		})
		_saved_class_request.call({
			"candidate_token": CLASS_REQUEST_TOKEN,
			"frame": 0,
			"tool_id": &"box",
		})
	if mode in ["fail_after_connect", "fail_after_hostile_viewport", "fail_after_hostile_viewport_and_class_request"]:
		return PackedStringArray(["fixture edit activation failure"])
	_active = true
	_active_tool = &"select"
	return PackedStringArray()


func deactivate() -> void:
	deactivation_count += 1
	if _hostile_viewport_lifecycle:
		_mutate_saved_viewport("deactivate")
	cancel()
	_cleanup_connection()
	_viewport = null
	_saved_frame_getter = Callable()
	_saved_selection_getter = Callable()
	_saved_selection_setter = Callable()
	_saved_class_request = Callable()
	_saved_edit_state_changed = Callable()
	_active = false
	_active_tool = &"select"
	_hostile_viewport_lifecycle = false
	_pending_class_token = -1


func set_active_tool(tool_id: StringName) -> PackedStringArray:
	if tool_id not in [&"select", &"move", &"box", &"fill", &"delete"]:
		return PackedStringArray(["unsupported fixture tool"])
	cancel()
	_active_tool = tool_id
	return PackedStringArray()


func get_active_tool() -> StringName:
	return _active_tool


func read_saved_frame() -> int:
	return int(_saved_frame_getter.call())


func read_saved_selection() -> String:
	return str(_saved_selection_getter.call())


func write_saved_selection(region_id: String) -> void:
	_saved_selection_setter.call(region_id)


func write_saved_viewport(record: Dictionary, region_id: String, overlay: Dictionary) -> void:
	if _viewport == null:
		return
	_viewport.set_record(record.duplicate(true))
	_viewport.set_selected_region_id(region_id)
	_viewport.set_edit_overlay(overlay.duplicate(true))


func handle_pointer(_event: InputEvent, _image_position: Vector2) -> void:
	pass


func handle_key(_event: InputEvent) -> bool:
	return false


func begin_add_box() -> void:
	_active_tool = &"box"
	transient_preview = true


func cancel() -> void:
	transient_preview = false


func relabel_selected(_class_label: String) -> PackedStringArray:
	return PackedStringArray()


func set_selected_track_id(_track_id: Variant) -> PackedStringArray:
	return PackedStringArray()


func set_selected_fill(_filled: bool) -> PackedStringArray:
	return PackedStringArray()


func set_selected_geometry(_box: Array) -> PackedStringArray:
	return PackedStringArray()


func delete_selected() -> PackedStringArray:
	return PackedStringArray()


func _on_cancel_signal() -> void:
	cancel_signal_count += 1
	cancel()


func _cleanup_connection() -> void:
	if _connected and _viewport != null and is_instance_valid(_viewport):
		var callback := Callable(self, "_on_cancel_signal")
		if _viewport.is_connected("edit_cancel_requested", callback):
			_viewport.disconnect("edit_cancel_requested", callback)
	_connected = false


func _mutate_saved_viewport(stage: String) -> void:
	if _viewport == null:
		return
	_viewport.clear_edit_overlay()
	_viewport.set_record({
		"schema_version": 1,
		"source": "hostile-candidate",
		"frame": 999,
		"regions": [],
	})
	_viewport.set_selected_region_id("hostile-%s-selection" % stage)
	_viewport.set_edit_overlay({
		"phase": &"drawing",
		"path": PackedVector2Array([Vector2(1, 1), Vector2(2, 2)]),
		"source": stage,
	})
	var transform = _viewport.get_image_transform()
	if transform != null and transform.has_method("pan_by"):
		transform.pan_by(Vector2(17, -9))
