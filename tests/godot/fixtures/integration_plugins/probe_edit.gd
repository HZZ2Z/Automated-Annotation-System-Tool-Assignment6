extends RefCounted

static var mode := "success"
static var activation_count := 0
static var deactivation_count := 0
static var last_activation_frame := -999
static var last_activation_selection := "unset"

var transient_preview := false
var cancel_signal_count := 0
var _viewport: Variant
var _connected := false
var _active := false
var _saved_frame_getter := Callable()
var _saved_selection_getter := Callable()
var _saved_selection_setter := Callable()


static func reset(next_mode: String = "success") -> void:
	mode = next_mode
	activation_count = 0
	deactivation_count = 0
	last_activation_frame = -999
	last_activation_selection = "unset"


func activate(context: Dictionary) -> PackedStringArray:
	activation_count += 1
	if context.is_empty():
		return PackedStringArray(["fixture does not define empty-context teardown"])
	_saved_frame_getter = context.get("get_current_frame")
	_saved_selection_getter = context.get("get_selected_region")
	_saved_selection_setter = context.get("set_selected_region")
	last_activation_frame = int(_saved_frame_getter.call())
	last_activation_selection = str(_saved_selection_getter.call())
	_saved_selection_setter.call("candidate-staged-selection")
	_viewport = context.get("viewport")
	if _viewport != null and _viewport.has_signal("edit_cancel_requested"):
		_viewport.edit_cancel_requested.connect(_on_cancel_signal)
		_connected = true
	if mode == "fail_after_connect":
		return PackedStringArray(["fixture edit activation failure"])
	_active = true
	return PackedStringArray()


func deactivate() -> void:
	deactivation_count += 1
	cancel()
	_cleanup_connection()
	_viewport = null
	_saved_frame_getter = Callable()
	_saved_selection_getter = Callable()
	_saved_selection_setter = Callable()
	_active = false


func read_saved_frame() -> int:
	return int(_saved_frame_getter.call())


func read_saved_selection() -> String:
	return str(_saved_selection_getter.call())


func write_saved_selection(region_id: String) -> void:
	_saved_selection_setter.call(region_id)


func handle_pointer(_event: InputEvent, _image_position: Vector2) -> void:
	pass


func handle_key(_event: InputEvent) -> bool:
	return false


func begin_add_box() -> void:
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
