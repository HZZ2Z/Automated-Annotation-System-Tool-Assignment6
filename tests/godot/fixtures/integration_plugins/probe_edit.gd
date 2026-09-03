extends RefCounted

static var mode := "success"
static var activation_count := 0
static var deactivation_count := 0

var transient_preview := false
var cancel_signal_count := 0
var _viewport: Variant
var _connected := false
var _active := false


static func reset(next_mode: String = "success") -> void:
	mode = next_mode
	activation_count = 0
	deactivation_count = 0


func activate(context: Dictionary) -> PackedStringArray:
	activation_count += 1
	if context.is_empty():
		return PackedStringArray(["fixture does not define empty-context teardown"])
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
	_active = false


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
