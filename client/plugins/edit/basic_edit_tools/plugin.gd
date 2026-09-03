extends RefCounted


const MOVE_COMMAND := preload("res://client/domain/commands/move_region_command.gd")
const RESIZE_COMMAND := preload("res://client/domain/commands/resize_box_command.gd")
const ADD_COMMAND := preload("res://client/domain/commands/add_box_command.gd")
const DELETE_COMMAND := preload("res://client/domain/commands/delete_region_command.gd")
const RELABEL_COMMAND := preload("res://client/domain/commands/relabel_region_command.gd")
const TRACK_COMMAND := preload("res://client/domain/commands/set_track_id_command.gd")
const FILL_COMMAND := preload("res://client/domain/commands/toggle_fill_command.gd")
const HANDLE_TOLERANCE_VIEWPORT_PX := 8.0

var _store: Variant
var _history: Variant
var _viewport: Variant
var _current_frame_getter := Callable()
var _selected_region_getter := Callable()
var _selected_region_setter := Callable()
var _status_callback := Callable()
var _taxonomy: Dictionary = {}
var _active := false

var _add_pointer_mode := false
var _drag_kind := ""
var _drag_frame := -1
var _drag_region_id := ""
var _drag_start := Vector2.ZERO
var _drag_before: Dictionary = {}
var _resize_handle := -1
var _preview_record: Dictionary = {}
var _keyboard_box: Array = []


func activate(context: Dictionary) -> PackedStringArray:
	if _active:
		cancel()
	_disconnect_viewport_cancel()
	_clear_transient()
	_active = false
	var errors := PackedStringArray()
	var status_candidate := _context_callable(context, ["status", "status_callback"])
	_status_callback = Callable()
	_store = context.get("store")
	_history = context.get("history")
	_viewport = context.get("viewport")
	_current_frame_getter = _context_callable(context, ["current_frame", "current_frame_getter", "get_current_frame"])
	_selected_region_getter = _context_callable(context, ["selected_region", "selected_region_getter", "get_selected_region"])
	_selected_region_setter = _context_callable(context, ["set_selected_region", "selected_region_setter"])
	var taxonomy_value: Variant = context.get("taxonomy")
	_taxonomy = taxonomy_value.duplicate(true) if taxonomy_value is Dictionary else {}
	_require_object_method(_store, "store", "get_corrected_record", 1, errors)
	_require_object_method(_store, "store", "replace_corrected_record", 2, errors)
	_require_object_method(_history, "history", "execute", 2, errors)
	_require_object_method(_history, "history", "undo", 1, errors)
	_require_object_method(_history, "history", "redo", 1, errors)
	_require_object_method(_viewport, "viewport", "set_record", 1, errors)
	_require_object_method(_viewport, "viewport", "set_selected_region_id", 1, errors)
	_require_object_method(_viewport, "viewport", "get_image_transform", 0, errors)
	_validate_callable_arity(_current_frame_getter, "current_frame", 0, errors)
	_validate_callable_arity(_selected_region_getter, "selected_region", 0, errors)
	_validate_callable_arity(_selected_region_setter, "set_selected_region", 1, errors)
	if _validate_callable_arity(status_candidate, "status", 1, errors):
		_status_callback = status_candidate
	if not taxonomy_value is Dictionary:
		errors.append("context.taxonomy: expected a Dictionary")
	if not errors.is_empty():
		_report_errors(errors)
		return errors
	_active = true
	_connect_viewport_cancel()
	return errors


func deactivate() -> void:
	cancel()
	_disconnect_viewport_cancel()
	_clear_transient()
	_store = null
	_history = null
	_viewport = null
	_current_frame_getter = Callable()
	_selected_region_getter = Callable()
	_selected_region_setter = Callable()
	_status_callback = Callable()
	_taxonomy = {}
	_active = false


func handle_pointer(event: InputEvent, image_position: Vector2) -> void:
	if not _active or not image_position.is_finite():
		return
	if event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if event.pressed:
			_begin_pointer_drag(event, image_position)
		else:
			_finish_pointer_drag(image_position)
		return
	if event is InputEventMouseMotion and _is_pointer_drag():
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT == 0:
			cancel()
			return
		_update_pointer_preview(image_position)


func handle_key(event: InputEvent) -> bool:
	if not _active or not event is InputEventKey or not event.pressed or event.echo:
		return false
	var key: Key = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	if key == KEY_ESCAPE:
		cancel()
		return true
	if _add_pointer_mode or _is_pointer_drag():
		return true
	if _drag_kind == "keyboard_add":
		return _handle_keyboard_add_key(event, key)
	if event.ctrl_pressed and key == KEY_Z:
		if event.shift_pressed:
			var redo_errors: PackedStringArray = _history.redo(_store)
			if not redo_errors.is_empty():
				_report_errors(redo_errors)
		else:
			_history.undo(_store)
		_refresh_current_frame()
		return true
	if key == KEY_TAB:
		_cycle_selection(-1 if event.shift_pressed else 1)
		return true
	if key == KEY_A and not event.ctrl_pressed and not event.alt_pressed:
		_begin_keyboard_add()
		return true
	if key == KEY_DELETE or key == KEY_BACKSPACE:
		delete_selected()
		return true
	var direction := _arrow_direction(key)
	if direction == Vector2.ZERO:
		return false
	var frame := _current_frame()
	var region_id := _selected_region_id()
	var record := _record_for_frame(frame)
	if frame < 0 or region_id.is_empty() or record.is_empty():
		_report("Select a region before editing it")
		return true
	var step := _key_step(event)
	var command: Variant
	if event.alt_pressed:
		var region := _find_region(record, region_id)
		if region.is_empty() or not region.has("box"):
			_report("Resize is supported only for boxes")
			return true
		var box: Array = region["box"].duplicate(true)
		box[2] = float(box[2]) + direction.x * step
		box[3] = float(box[3]) + direction.y * step
		command = RESIZE_COMMAND.new(frame, record, region_id, box)
	else:
		command = MOVE_COMMAND.new(frame, record, region_id, direction * step)
	_execute(command, frame)
	return true


func begin_add_box() -> void:
	if not _active:
		return
	cancel()
	_add_pointer_mode = true
	_report("Drag to create a box; press Escape to cancel")


func cancel() -> void:
	if not _active:
		_clear_transient()
		return
	var restore_frame := _drag_frame
	var had_preview := not _drag_kind.is_empty() or _add_pointer_mode
	_clear_transient()
	if had_preview:
		_refresh_visible_frame(restore_frame)


func relabel_selected(class_label: String) -> PackedStringArray:
	return _execute_selected(RELABEL_COMMAND, class_label)


func set_selected_track_id(track_id: Variant) -> PackedStringArray:
	return _execute_selected(TRACK_COMMAND, track_id)


func set_selected_fill(filled: bool) -> PackedStringArray:
	return _execute_selected(FILL_COMMAND, filled)


func set_selected_geometry(box: Array) -> PackedStringArray:
	return _execute_selected(RESIZE_COMMAND, box.duplicate(true))


func delete_selected() -> PackedStringArray:
	if not _active:
		return PackedStringArray(["edit plugin is not active"])
	var frame := _current_frame()
	var region_id := _selected_region_id()
	var record := _record_for_frame(frame)
	if frame < 0 or region_id.is_empty() or record.is_empty():
		var errors := PackedStringArray(["Select a region before deleting it"])
		_report_errors(errors)
		return errors
	var errors := _execute(DELETE_COMMAND.new(frame, record, region_id), frame)
	if errors.is_empty():
		_set_selected_region("")
	return errors


func _begin_pointer_drag(event: InputEventMouseButton, image_position: Vector2) -> void:
	if _drag_kind == "keyboard_add" or _is_pointer_drag():
		cancel()
	var frame := _current_frame()
	var record := _record_for_frame(frame)
	if frame < 0 or record.is_empty():
		return
	if _add_pointer_mode:
		_add_pointer_mode = false
		_drag_kind = "add"
		_drag_frame = frame
		_drag_start = image_position
		_drag_before = record.duplicate(true)
		return
	var selected_id := _selected_region_id()
	var selected_region := _find_region(record, selected_id)
	if not selected_region.is_empty() and selected_region.has("box"):
		var selected_handle := _box_handle_at(selected_region["box"], event.position)
		if selected_handle >= 0:
			_drag_kind = "resize"
			_resize_handle = selected_handle
			_drag_frame = frame
			_drag_region_id = selected_id
			_drag_start = image_position
			_drag_before = record.duplicate(true)
			return
	var hit := _hit_test(record, image_position)
	if hit.is_empty():
		_set_selected_region("")
		return
	var region_id := str(hit.get("id", ""))
	_set_selected_region(region_id)
	_drag_kind = "move"
	_resize_handle = -1
	if hit.has("box"):
		_resize_handle = _box_handle_at(hit["box"], event.position)
		if _resize_handle >= 0:
			_drag_kind = "resize"
	_drag_frame = frame
	_drag_region_id = region_id
	_drag_start = image_position
	_drag_before = record.duplicate(true)


func _update_pointer_preview(image_position: Vector2) -> void:
	if _drag_before.is_empty():
		return
	var preview := _drag_before.duplicate(true)
	match _drag_kind:
		"move":
			_apply_preview_move(preview, _drag_region_id, image_position - _drag_start)
		"resize":
			_apply_preview_resize(preview, _drag_region_id, image_position)
		"add":
			_append_preview_box(preview, _normalized_box(_drag_start, image_position))
		_:
			return
	_preview_record = preview.duplicate(true)
	_viewport.set_record(_preview_record.duplicate(true))


func _finish_pointer_drag(image_position: Vector2) -> void:
	if _drag_kind.is_empty() or _drag_kind == "keyboard_add":
		return
	var kind := _drag_kind
	var frame := _drag_frame
	var region_id := _drag_region_id
	var before := _drag_before.duplicate(true)
	var start := _drag_start
	var handle := _resize_handle
	_clear_transient()
	var command: Variant
	match kind:
		"move":
			var delta := image_position - start
			if delta.is_zero_approx():
				_refresh_visible_frame(frame)
				return
			command = MOVE_COMMAND.new(frame, before, region_id, delta)
		"resize":
			var region := _find_region(before, region_id)
			var box := _resized_box(region.get("box", []), handle, image_position)
			if _numeric_arrays_approx_equal(box, region.get("box", [])):
				_refresh_visible_frame(frame)
				return
			command = RESIZE_COMMAND.new(frame, before, region_id, box)
		"add":
			command = ADD_COMMAND.new(frame, before, _normalized_box(start, image_position), _default_class(), _default_kind())
	var errors := _execute(command, frame)
	if errors.is_empty() and kind == "add":
		_select_added_if_still_current(frame, command.get_region_id())


func _begin_keyboard_add() -> void:
	cancel()
	var frame := _current_frame()
	var record := _record_for_frame(frame)
	if frame < 0 or record.is_empty():
		_report("Cannot add a box without a current frame")
		return
	var dimensions: Variant = record.get("image_size", [])
	if not dimensions is Array or dimensions.size() != 2:
		_report("Current frame has no valid image size")
		return
	_keyboard_box = [0.0, 0.0, minf(20.0, float(dimensions[0])), minf(20.0, float(dimensions[1]))]
	_drag_kind = "keyboard_add"
	_drag_frame = frame
	_drag_before = record.duplicate(true)
	_show_keyboard_add_preview()
	_report("Keyboard box: arrows move, Alt+arrows resize, Enter confirms, Escape cancels")


func _handle_keyboard_add_key(event: InputEventKey, key: Key) -> bool:
	if key == KEY_ENTER or key == KEY_KP_ENTER:
		var frame := _drag_frame
		var before := _drag_before.duplicate(true)
		var box := _keyboard_box.duplicate(true)
		_clear_transient()
		var command = ADD_COMMAND.new(frame, before, box, _default_class(), _default_kind())
		var errors := _execute(command, frame)
		if errors.is_empty():
			_select_added_if_still_current(frame, command.get_region_id())
		return true
	var direction := _arrow_direction(key)
	if direction == Vector2.ZERO:
		return false
	var step := _key_step(event)
	if event.alt_pressed:
		_keyboard_box[2] = float(_keyboard_box[2]) + direction.x * step
		_keyboard_box[3] = float(_keyboard_box[3]) + direction.y * step
	else:
		_keyboard_box[0] = float(_keyboard_box[0]) + direction.x * step
		_keyboard_box[1] = float(_keyboard_box[1]) + direction.y * step
	_show_keyboard_add_preview()
	return true


func _show_keyboard_add_preview() -> void:
	var preview := _drag_before.duplicate(true)
	_append_preview_box(preview, _keyboard_box)
	_preview_record = preview.duplicate(true)
	_viewport.set_record(_preview_record.duplicate(true))


func _execute_selected(command_script: Script, value: Variant) -> PackedStringArray:
	if not _active:
		return PackedStringArray(["edit plugin is not active"])
	var frame := _current_frame()
	var region_id := _selected_region_id()
	var record := _record_for_frame(frame)
	if frame < 0 or region_id.is_empty() or record.is_empty():
		var missing := PackedStringArray(["Select a region before editing it"])
		_report_errors(missing)
		return missing
	var command = command_script.new(frame, record, region_id, value)
	return _execute(command, frame)


func _execute(command: Variant, frame: int) -> PackedStringArray:
	var errors: PackedStringArray = _history.execute(command, _store)
	if not errors.is_empty():
		_report_errors(errors)
	_refresh_visible_frame(frame)
	return errors


func _refresh_current_frame() -> void:
	_refresh_visible_frame(-1)


func _refresh_visible_frame(fallback_frame: int) -> void:
	var current := _current_frame()
	if current >= 0 and not _record_for_frame(current).is_empty():
		_refresh_frame(current)
		return
	_refresh_frame(fallback_frame)


func _refresh_frame(frame: int) -> void:
	if frame < 0 or not _is_live_object(_viewport):
		return
	var record := _record_for_frame(frame)
	if not record.is_empty():
		_viewport.set_record(record.duplicate(true))


func _cycle_selection(direction: int) -> void:
	var record := _record_for_frame(_current_frame())
	var regions: Variant = record.get("regions", [])
	if not regions is Array or regions.is_empty():
		_set_selected_region("")
		return
	var current := _selected_region_id()
	var index := -1
	for candidate_index in range(regions.size()):
		var candidate: Variant = regions[candidate_index]
		if candidate is Dictionary and candidate.get("id") == current:
			index = candidate_index
			break
	var next_index := 0
	if index >= 0:
		next_index = posmod(index + direction, regions.size())
	elif direction < 0:
		next_index = regions.size() - 1
	_set_selected_region(str(regions[next_index].get("id", "")))


func _set_selected_region(region_id: String) -> void:
	_selected_region_setter.call(region_id)
	_viewport.set_selected_region_id(region_id)


func _select_added_if_still_current(frozen_frame: int, region_id: String) -> void:
	if _current_frame() == frozen_frame:
		_set_selected_region(region_id)
		return
	_validate_current_selection()


func _validate_current_selection() -> void:
	var current_record := _record_for_frame(_current_frame())
	var selected_id := _selected_region_id()
	if selected_id.is_empty():
		return
	if _find_region(current_record, selected_id).is_empty():
		_set_selected_region("")


func _current_frame() -> int:
	if not _current_frame_getter.is_valid():
		return -1
	var value: Variant = _current_frame_getter.call()
	if (typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT) or not is_finite(float(value)) or float(value) != floorf(float(value)) or value < 0:
		_report("Current frame getter must return a non-negative integer")
		return -1
	return int(value)


func _selected_region_id() -> String:
	if not _selected_region_getter.is_valid():
		return ""
	var value: Variant = _selected_region_getter.call()
	if typeof(value) == TYPE_STRING:
		return value
	if value is Dictionary:
		return str(value.duplicate(true).get("id", ""))
	if value != null:
		_report("Selected-region getter must return a region ID, region snapshot, or null")
	return ""


func _record_for_frame(frame: int) -> Dictionary:
	if frame < 0:
		return {}
	var value: Variant = _store.get_corrected_record(frame)
	return value.duplicate(true) if value is Dictionary else {}


func _find_region(record: Dictionary, region_id: String) -> Dictionary:
	var regions: Variant = record.get("regions", [])
	if regions is Array:
		for value: Variant in regions:
			if value is Dictionary and value.get("id") == region_id:
				return value.duplicate(true)
	return {}


func _hit_test(record: Dictionary, point: Vector2) -> Dictionary:
	var regions: Variant = record.get("regions", [])
	if not regions is Array:
		return {}
	for index in range(regions.size() - 1, -1, -1):
		var value: Variant = regions[index]
		if not value is Dictionary:
			continue
		var region: Dictionary = value
		var box: Variant = region.get("box")
		if box is Array and box.size() == 4 and Rect2(float(box[0]), float(box[1]), float(box[2]), float(box[3])).has_point(point):
			return region.duplicate(true)
		var polygon := _polygon_points(region.get("polygon"))
		if polygon.size() >= 3 and Geometry2D.is_point_in_polygon(point, polygon):
			return region.duplicate(true)
	return {}


func _box_handle_at(box: Variant, viewport_point: Vector2) -> int:
	if not box is Array or box.size() != 4:
		return -1
	var transform: Variant = _viewport.get_image_transform()
	if not transform is Object or not transform.has_method("image_to_viewport"):
		return -1
	var rect := Rect2(float(box[0]), float(box[1]), float(box[2]), float(box[3]))
	var center := rect.get_center()
	var handles := [rect.position, Vector2(center.x, rect.position.y), Vector2(rect.end.x, rect.position.y), Vector2(rect.end.x, center.y), rect.end, Vector2(center.x, rect.end.y), Vector2(rect.position.x, rect.end.y), Vector2(rect.position.x, center.y)]
	for index in range(handles.size()):
		if transform.image_to_viewport(handles[index]).distance_to(viewport_point) <= HANDLE_TOLERANCE_VIEWPORT_PX:
			return index
	return -1


func _apply_preview_move(record: Dictionary, region_id: String, delta: Vector2) -> void:
	var regions: Array = record.get("regions", [])
	for region: Dictionary in regions:
		if region.get("id") != region_id:
			continue
		if region.has("box"):
			region["box"][0] = float(region["box"][0]) + delta.x
			region["box"][1] = float(region["box"][1]) + delta.y
		else:
			for point: Array in region.get("polygon", []):
				point[0] = float(point[0]) + delta.x
				point[1] = float(point[1]) + delta.y
		return


func _apply_preview_resize(record: Dictionary, region_id: String, point: Vector2) -> void:
	var regions: Array = record.get("regions", [])
	for region: Dictionary in regions:
		if region.get("id") == region_id:
			region["box"] = _resized_box(region.get("box", []), _resize_handle, point)
			return


func _resized_box(box: Variant, handle: int, point: Vector2) -> Array:
	if not box is Array or box.size() != 4:
		return []
	var left := float(box[0])
	var top := float(box[1])
	var right := left + float(box[2])
	var bottom := top + float(box[3])
	if handle in [0, 6, 7]:
		left = point.x
	if handle in [0, 1, 2]:
		top = point.y
	if handle in [2, 3, 4]:
		right = point.x
	if handle in [4, 5, 6]:
		bottom = point.y
	return [left, top, right - left, bottom - top]


func _normalized_box(start: Vector2, finish: Vector2) -> Array:
	var left := minf(start.x, finish.x)
	var top := minf(start.y, finish.y)
	return [left, top, absf(finish.x - start.x), absf(finish.y - start.y)]


func _append_preview_box(record: Dictionary, box: Array) -> void:
	var regions: Variant = record.get("regions", [])
	if regions is Array:
		regions.append({"id": "__new_box_preview", "class": _default_class(), "kind": _default_kind(), "box": box.duplicate(true), "track_id": null, "filled": false})


func _default_class() -> String:
	var classes: Variant = _taxonomy.get("classes", [])
	if classes is Array:
		for value: Variant in classes:
			if value is Dictionary and typeof(value.get("id")) == TYPE_STRING and not String(value.get("id")).is_empty():
				return value.get("id")
	return "unknown"


func _default_kind() -> String:
	var class_id := _default_class()
	var classes: Variant = _taxonomy.get("classes", [])
	if classes is Array:
		for value: Variant in classes:
			if value is Dictionary and value.get("id") == class_id and typeof(value.get("kind")) == TYPE_STRING and not String(value.get("kind")).is_empty():
				return value.get("kind")
	return "region"


func _arrow_direction(key: Key) -> Vector2:
	match key:
		KEY_LEFT:
			return Vector2.LEFT
		KEY_RIGHT:
			return Vector2.RIGHT
		KEY_UP:
			return Vector2.UP
		KEY_DOWN:
			return Vector2.DOWN
	return Vector2.ZERO


func _key_step(event: InputEventKey) -> float:
	return 10.0 if event.ctrl_pressed and event.shift_pressed else (5.0 if event.shift_pressed else 1.0)


func _polygon_points(value: Variant) -> PackedVector2Array:
	var result := PackedVector2Array()
	if not value is Array:
		return result
	for point: Variant in value:
		if not point is Array or point.size() != 2:
			return PackedVector2Array()
		result.append(Vector2(float(point[0]), float(point[1])))
	return result


func _numeric_arrays_approx_equal(left: Variant, right: Variant) -> bool:
	if not left is Array or not right is Array or left.size() != right.size():
		return false
	for index in range(left.size()):
		var left_value: Variant = left[index]
		var right_value: Variant = right[index]
		if (typeof(left_value) != TYPE_INT and typeof(left_value) != TYPE_FLOAT) or not is_finite(float(left_value)):
			return false
		if (typeof(right_value) != TYPE_INT and typeof(right_value) != TYPE_FLOAT) or not is_finite(float(right_value)):
			return false
		if not is_equal_approx(float(left_value), float(right_value)):
			return false
	return true


func _clear_transient() -> void:
	_add_pointer_mode = false
	_drag_kind = ""
	_drag_frame = -1
	_drag_region_id = ""
	_drag_start = Vector2.ZERO
	_drag_before = {}
	_resize_handle = -1
	_preview_record = {}
	_keyboard_box = []


func _is_pointer_drag() -> bool:
	return _drag_kind == "move" or _drag_kind == "resize" or _drag_kind == "add"


func _connect_viewport_cancel() -> void:
	if _is_live_object(_viewport) and _viewport.has_signal("edit_cancel_requested"):
		var callback := Callable(self, "cancel")
		if not _viewport.is_connected("edit_cancel_requested", callback):
			_viewport.connect("edit_cancel_requested", callback)


func _disconnect_viewport_cancel() -> void:
	if _is_live_object(_viewport) and _viewport.has_signal("edit_cancel_requested"):
		var callback := Callable(self, "cancel")
		if _viewport.is_connected("edit_cancel_requested", callback):
			_viewport.disconnect("edit_cancel_requested", callback)


func _report_errors(errors: PackedStringArray) -> void:
	if not errors.is_empty():
		_report("; ".join(errors))


func _report(message: String) -> void:
	if _status_callback.is_valid():
		_status_callback.call(message)


func _context_callable(context: Dictionary, keys: Array[String]) -> Callable:
	for key: String in keys:
		var value: Variant = context.get(key)
		if value is Callable:
			return value
	return Callable()


func _require_object_method(value: Variant, field: String, method: String, expected: int, errors: PackedStringArray) -> void:
	if not _is_live_object(value) or not value.has_method(method):
		errors.append("context.%s: expected an object providing %s" % [field, method])
		return
	if not _method_accepts_argument_count(value, method, expected):
		errors.append("context.%s.%s: method must accept %d argument(s)" % [field, method, expected])


func _method_accepts_argument_count(value: Object, method: String, expected: int) -> bool:
	for method_info: Dictionary in value.get_method_list():
		if method_info.get("name", "") != method:
			continue
		var arguments: Array = method_info.get("args", [])
		var defaults: Array = method_info.get("default_args", [])
		var minimum := maxi(0, arguments.size() - defaults.size())
		var is_vararg := int(method_info.get("flags", 0)) & METHOD_FLAG_VARARG != 0
		return expected >= minimum and (is_vararg or expected <= arguments.size())
	return false


func _is_live_object(value: Variant) -> bool:
	return typeof(value) == TYPE_OBJECT and value != null and is_instance_valid(value)


func _validate_callable_arity(value: Callable, field: String, expected: int, errors: PackedStringArray) -> bool:
	if not value.is_valid():
		errors.append("context.%s: expected a valid Callable with %d argument(s)" % [field, expected])
		return false
	var actual := value.get_argument_count()
	if actual != expected:
		errors.append("context.%s: Callable must accept %d argument(s), got %d" % [field, expected, actual])
		return false
	return true
