extends "res://client/pipeline/stages/edit_stage.gd"


const MOVE_COMMAND := preload("res://client/domain/commands/move_region_command.gd")
const RESIZE_COMMAND := preload("res://client/domain/commands/resize_box_command.gd")
const ADD_COMMAND := preload("res://client/domain/commands/add_box_command.gd")
const ADD_POLYGON_COMMAND := preload("res://client/domain/commands/add_polygon_command.gd")
const REPLACE_GEOMETRY_COMMAND := preload("res://client/domain/commands/replace_region_geometry_command.gd")
const REPLACE_FRAME_COMMAND := preload("res://client/domain/commands/replace_frame_command.gd")
const DELETE_COMMAND := preload("res://client/domain/commands/delete_region_command.gd")
const RELABEL_COMMAND := preload("res://client/domain/commands/relabel_region_command.gd")
const TRACK_COMMAND := preload("res://client/domain/commands/set_track_id_command.gd")
const FILL_COMMAND := preload("res://client/domain/commands/toggle_fill_command.gd")
const PROPAGATE_COMMAND := preload("res://client/domain/commands/propagate_range_command.gd")
const REGION_GEOMETRY := preload("res://client/domain/region_geometry.gd")
const POLYGON_OPS := preload("res://client/domain/polygon_ops.gd")
const MASK_REGION_OPS := preload("res://client/domain/mask_region_ops.gd")
const EDIT_SESSION := preload("res://client/domain/edit_session.gd")
const FILL_SOLVER := preload("res://client/domain/fill_region_solver.gd")
const BRUSH_BUFFER := preload("res://client/domain/brush_stroke_buffer.gd")
const VERTEX_EDITOR := preload("res://client/plugins/edit/basic_edit_tools/polygon_vertex_editor.gd")
const HANDLE_TOLERANCE_VIEWPORT_PX := 8.0
const EDGE_TOLERANCE_VIEWPORT_PX := 6.0
const FREEHAND_SAMPLE_DISTANCE := 0.75
const FREEHAND_SIMPLIFY_TOLERANCE := 0.5
const FREEHAND_CLOSE_DISTANCE := 3.0
const FREEHAND_CLOSE_VIEWPORT_PX := 12.0
const GESTURE_BOUNDARY_RADIUS := 1.25
const LASSO_DRAG_THRESHOLD_IMAGE_PX := 2.0
const MAX_GESTURE_POINTS := 2048
const MAX_PREVIEW_POINTS := 128
const PAINT_OVERLAY_COLOR := Color("#22d3ee")
const ERASER_OVERLAY_COLOR := Color("#a855f7")
const TOOL_IDS: Array[StringName] = [
	&"box", &"subtract", &"lasso", &"fill",
	&"paint", &"eraser", &"select",
]
const BRUSH_OPTION := {
	"id": &"brush_radius", "label": "Brush radius", "kind": &"float_range",
	"min": 1.0, "max": 40.0, "step": 1.0, "default": 8.0,
	"shared_key": &"brush_radius",
}
const FILL_OPTION := {
	"id": &"fill_gap_radius", "label": "Gap radius (px)", "kind": &"float_range",
	"min": 0.0, "max": 3.0, "step": 1.0, "default": 1.0,
}
const TOOL_DESCRIPTORS: Array[Dictionary] = [
	{"id": &"box", "node_name": "Box", "label": "Add Box", "presentation_text": "Add\nBox", "implemented": true, "tooltip": "Drag to add a box", "icon_path": "res://client/ui/icons/tools/add_box.svg"},
	{"id": &"subtract", "node_name": "Subtract", "label": "Subtract", "implemented": true, "tooltip": "Subtract from the selected region, or delete across all regions when none is selected", "icon_path": "res://client/ui/icons/tools/subtract.svg"},
	{"id": &"lasso", "node_name": "Lasso", "label": "Lasso", "implemented": true, "tooltip": "Draw a polygon, or edit selected polygon vertices: drag points, double-click edges to insert, Delete to remove", "icon_path": "res://client/ui/icons/tools/lasso.svg"},
	{"id": &"fill", "node_name": "Fill", "label": "Fill", "implemented": true, "tooltip": "Fill an enclosed area; preview small gap repairs before applying", "icon_path": "res://client/ui/icons/tools/fill.svg", "options": [FILL_OPTION]},
	{"id": &"paint", "node_name": "Paint", "label": "Paint", "implemented": true, "tooltip": "Repair one overlapped region, or paint a new object", "icon_path": "res://client/ui/icons/tools/paint.svg", "options": [BRUSH_OPTION]},
	{"id": &"eraser", "node_name": "Eraser", "label": "Eraser", "implemented": true, "tooltip": "Erase every region touched by the stroke; no selection needed", "icon_path": "res://client/ui/icons/tools/erase.svg", "options": [BRUSH_OPTION]},
	{"id": &"select", "node_name": "Select", "label": "Selection", "implemented": true, "default": true, "tooltip": "Select, move, or resize a region", "icon_path": "res://client/ui/icons/tools/selection.svg"},
]

var _vertex_editor = VERTEX_EDITOR.new()
var _vertex_mode_requested := false
var _store: Variant
var _history: Variant
var _viewport: Variant
var _current_frame_getter := Callable()
var _selected_region_getter := Callable()
var _selected_region_setter := Callable()
var _current_image_getter := Callable()
var _status_callback := Callable()
var _edit_state_callback := Callable()
var _request_class_assignment := Callable()
var _taxonomy: Dictionary = {}
var _active := false
var _active_tool: StringName = &"select"
var _brush_radius_image_px := 8.0
var _fill_gap_radius := 1
var _brush_buffer = BRUSH_BUFFER.new()
var _buffered_points := 0
var _brush_error := ""
var _last_pointer_image_position := Vector2.ZERO
var _has_last_pointer_image_position := false
var _session = EDIT_SESSION.new()
var _candidate_token := 0

var _add_pointer_mode := false
var _drag_kind := ""
var _drag_frame := -1
var _drag_region_id := ""
var _drag_start := Vector2.ZERO
var _drag_before: Dictionary = {}
var _drag_image_size := Vector2.ZERO
var _resize_handle := -1
var _keyboard_box: Array = []
var _stroke_points := PackedVector2Array()
var _brush_region_masks: Array[Dictionary] = []
var _lasso_mode: StringName = &""
var _lasso_anchors := PackedVector2Array()
var _lasso_press_position := Vector2.ZERO
var _lasso_release_suppressed := false
var _lasso_invalid_message := ""
var _lasso_active_anchor := -1
var _lasso_vertex_moved := false
var _keyboard_tool: StringName = &""
var _keyboard_cursor := Vector2.ZERO
var _keyboard_points := PackedVector2Array()
var _keyboard_frame := -1
var _keyboard_region_id := ""
var _keyboard_before: Dictionary = {}


func get_tool_descriptors() -> Array[Dictionary]:
	return TOOL_DESCRIPTORS.duplicate(true)


func get_edit_state() -> Dictionary:
	return {
		"phase": _session.phase,
		"gesture_active": _has_transient_edit() or _add_pointer_mode,
		"navigation_blocked": _session.has_working_mask() or _session.has_pending_class_assignment() or _session.has_fill_repair(),
		"draft_active": _session.has_working_mask() or _session.has_fill_repair(),
		"draft_history": _session.draft_counts(),
		"fill_repair": _session.has_fill_repair(),
		"message": String(_session.message),
	}.duplicate(true)


func invoke(action_id: StringName, payload: Dictionary = {}) -> PackedStringArray:
	if action_id == &"confirm_fill_repair":
		return _confirm_fill_repair()
	if action_id == &"cancel_fill_repair":
		_session.cancel_fill_repair()
		_push_session_overlay()
		return PackedStringArray()
	if action_id in [&"undo_draft", &"redo_draft"]:
		var errors: PackedStringArray = _session.change_draft_history(action_id == &"redo_draft")
		_push_session_overlay()
		_report_errors(errors)
		return errors
	if action_id == &"set_tool_option" and StringName(payload.get("option_id", &"")) == &"fill_gap_radius":
		var value: Variant = payload.get("value")
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)) or float(value) != floorf(float(value)) or float(value) < 0 or float(value) > 3:
			return PackedStringArray(["Fill gap radius must be 0, 1, 2 or 3 image pixels"])
		if _session.has_pending_class_assignment() or _session.has_fill_repair():
			return PackedStringArray(["Confirm or cancel the current candidate before changing gap radius"])
		_fill_gap_radius = int(value)
		return PackedStringArray()
	if action_id == &"confirm_pending_region":
		return _confirm_pending_region(payload)
	if action_id == &"cancel_pending_region":
		return _cancel_pending_region(payload)
	if _active and _session.has_pending_class_assignment():
		var pending_errors := PackedStringArray(["Choose a class and kind, or press Escape to discard the pending region"])
		_report_errors(pending_errors)
		return pending_errors
	if _active and _session.has_fill_repair():
		return PackedStringArray(["Confirm or cancel the Fill repair before another edit"])
	# Inspector/API edits are complete commands. Never let one commit behind a
	# frozen pointer or keyboard preview.
	if _active and _session.has_working_mask():
		var working_errors := PackedStringArray(["Finish the Fill contour or press Escape"])
		_report_errors(working_errors)
		return working_errors
	if _active and _has_transient_edit():
		cancel()
	match action_id:
		&"set_tool_option":
			if StringName(payload.get("option_id", &"")) != &"brush_radius":
				return PackedStringArray(["Unsupported tool option"])
			var value: Variant = payload.get("value")
			if (typeof(value) not in [TYPE_INT, TYPE_FLOAT]
					or not is_finite(float(value)) or float(value) < 1.0 or float(value) > 40.0):
				return PackedStringArray(["Brush radius must be a finite value from 1 to 40 image pixels"])
			_brush_radius_image_px = float(value)
			_show_idle_brush_cursor()
			return PackedStringArray()
		&"begin_add_box":
			begin_add_box()
			return PackedStringArray()
		&"relabel_selected":
			var class_value: Variant = payload.get("class", null)
			if typeof(class_value) != TYPE_STRING:
				var class_errors := PackedStringArray(["class: expected non-empty string"])
				_report_errors(class_errors)
				return class_errors
			if payload.has("kind"):
				var kind_value: Variant = payload.get("kind")
				if typeof(kind_value) != TYPE_STRING:
					var kind_errors := PackedStringArray(["kind: expected non-empty string"])
					_report_errors(kind_errors)
					return kind_errors
				return relabel_selected(String(class_value), kind_value)
			return relabel_selected(String(class_value))
		&"set_selected_track_id":
			return set_selected_track_id(payload.get("track_id"))
		&"set_selected_fill":
			return set_selected_fill(bool(payload.get("filled", false)))
		&"set_selected_geometry":
			var box: Variant = payload.get("box")
			return set_selected_geometry(box if box is Array else [])
		&"delete_selected":
			return delete_selected()
		&"range_propagate":
			var command = PROPAGATE_COMMAND.new(
				payload.get("keyframe"), payload.get("start_frame"), payload.get("end_frame"), str(payload.get("mode", ""))
			)
			var errors: PackedStringArray = _history.execute(command, _store) if _active else PackedStringArray(["edit plugin is not active"])
			if errors.is_empty():
				_refresh_current_frame()
			else:
				_report_errors(errors)
			return errors
	return PackedStringArray(["Unsupported edit action: %s" % action_id])


func activate(context: Dictionary) -> PackedStringArray:
	if _active:
		cancel()
	_disconnect_viewport_cancel()
	_clear_transient()
	_active = false
	_active_tool = &"select"
	var errors := PackedStringArray()
	var status_candidate := _context_callable(context, ["status", "status_callback"])
	var edit_state_candidate: Variant = context.get("edit_state_changed")
	var class_request_candidate: Variant = context.get("request_class_assignment")
	_status_callback = Callable()
	_edit_state_callback = Callable()
	_request_class_assignment = Callable()
	_store = context.get("store")
	_history = context.get("history")
	_viewport = context.get("viewport")
	_current_frame_getter = _context_callable(context, ["current_frame", "current_frame_getter", "get_current_frame"])
	_selected_region_getter = _context_callable(context, ["selected_region", "selected_region_getter", "get_selected_region"])
	_selected_region_setter = _context_callable(context, ["set_selected_region", "selected_region_setter"])
	_current_image_getter = _context_callable(context, ["get_current_image", "current_image_getter", "current_image"])
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
	if _current_image_getter.is_valid():
		_validate_callable_arity(_current_image_getter, "current_image", 0, errors)
	if _validate_callable_arity(status_candidate, "status", 1, errors):
		_status_callback = status_candidate
	if context.has("edit_state_changed"):
		if edit_state_candidate is Callable and _validate_callable_arity(edit_state_candidate, "edit_state_changed", 1, errors):
			_edit_state_callback = edit_state_candidate
		elif not edit_state_candidate is Callable:
			errors.append("context.edit_state_changed: expected a valid Callable with 1 argument(s)")
	if context.has("request_class_assignment"):
		if class_request_candidate is Callable and _validate_callable_arity(class_request_candidate, "request_class_assignment", 1, errors):
			_request_class_assignment = class_request_candidate
		elif not class_request_candidate is Callable:
			errors.append("context.request_class_assignment: expected a valid Callable with 1 argument(s)")
	if not taxonomy_value is Dictionary:
		errors.append("context.taxonomy: expected a Dictionary")
	if not errors.is_empty():
		_report_errors(errors)
		return errors
	_active = true
	_connect_viewport_cancel()
	_emit_edit_state()
	return errors


func deactivate() -> void:
	_clear_transient()
	_disconnect_viewport_cancel()
	_store = null
	_history = null
	_viewport = null
	_current_frame_getter = Callable()
	_selected_region_getter = Callable()
	_selected_region_setter = Callable()
	_current_image_getter = Callable()
	_status_callback = Callable()
	_edit_state_callback = Callable()
	_request_class_assignment = Callable()
	_taxonomy = {}
	_active = false
	_active_tool = &"select"
	_has_last_pointer_image_position = false


func set_active_tool(tool_id: StringName) -> PackedStringArray:
	if not _active:
		return PackedStringArray(["edit plugin is not active"])
	if _session.has_fill_repair():
		return PackedStringArray(["Confirm or cancel the Fill repair before changing tools"])
	if _session.has_pending_class_assignment():
		var pending_errors := PackedStringArray(["Choose a class and kind, or press Escape to discard the pending region"])
		_report_errors(pending_errors)
		return pending_errors
	if tool_id not in TOOL_IDS:
		var errors := PackedStringArray(["Unsupported edit tool: %s" % tool_id])
		_report_errors(errors)
		return errors
	if _session.has_working_mask():
		if tool_id != &"fill":
			var working_errors := PackedStringArray(["Finish the Fill contour or press Escape"])
			_report_errors(working_errors)
			return working_errors
		_active_tool = tool_id
		_add_pointer_mode = false
		return PackedStringArray()
	if tool_id == _active_tool:
		_show_idle_brush_cursor()
		_vertex_mode_requested = tool_id == &"lasso"
		refresh_edit_overlay()
		return PackedStringArray()
	_clear_transient()
	_active_tool = tool_id
	_vertex_mode_requested = tool_id == &"lasso"
	_add_pointer_mode = tool_id == &"box"
	_show_idle_brush_cursor()
	refresh_edit_overlay()
	return PackedStringArray()


func get_active_tool() -> StringName:
	return _active_tool


func refresh_edit_overlay() -> void:
	if _active and _active_tool == &"lasso" and _vertex_mode_requested and not _has_transient_edit():
		_vertex_editor.refresh(self)


func handle_pointer(event: InputEvent, image_position: Vector2) -> void:
	if not _active:
		return
	if _session.has_pending_class_assignment():
		return
	if _session.has_fill_repair():
		return
	if not image_position.is_finite():
		return
	_last_pointer_image_position = image_position
	_has_last_pointer_image_position = true
	if _active_tool == &"lasso":
		if _vertex_editor.pointer(self, event, image_position):
			return
		_handle_lasso_pointer(event, image_position)
		return
	if event is InputEventMouseMotion and _active_tool in [&"paint", &"eraser"] and not _is_pointer_drag():
		_show_idle_brush_cursor()
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
			return
		_update_pointer_preview(image_position)


func handle_key(event: InputEvent) -> bool:
	if not _active or not event is InputEventKey or not event.pressed or event.echo:
		return false
	var key: Key = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	if key == KEY_ESCAPE:
		if not _vertex_editor.region_id.is_empty():
			_vertex_editor.clear()
			_set_selected_region("")
		if _active_tool == &"select" and not _has_transient_edit():
			_set_selected_region("")
		if _session.has_fill_repair():
			_session.cancel_fill_repair()
			_push_session_overlay()
		else:
			cancel()
		return true
	if _session.has_pending_class_assignment():
		_report("Choose a class and kind, or press Escape to discard the pending region")
		return true
	if _session.has_working_mask() or _session.has_fill_repair():
		if event.ctrl_pressed and key in [KEY_Z, KEY_Y]:
			invoke(&"redo_draft" if key == KEY_Y or event.shift_pressed else &"undo_draft")
			return true
		if _session.has_fill_repair():
			if key in [KEY_ENTER, KEY_KP_ENTER]:
				_confirm_fill_repair()
			return key != KEY_TAB
		if key == KEY_F and not event.ctrl_pressed and not event.alt_pressed:
			return _begin_keyboard_spatial(&"fill")
		if _keyboard_tool != &"fill":
			_report("Press F to move a Fill seed with arrows, or Escape to discard the contour")
			return key != KEY_TAB
	if _active_tool == &"lasso" and _vertex_editor.key(self, event, key):
		return true
	if not _keyboard_tool.is_empty():
		return _handle_keyboard_spatial_key(event, key)
	if not _lasso_mode.is_empty():
		if _lasso_mode == &"vertex_drag":
			return key != KEY_TAB
		if key == KEY_BACKSPACE:
			_remove_lasso_anchor()
			return true
		if _edit_lasso_anchor_key(event, key):
			return true
		if key == KEY_SPACE:
			_finish_lasso_candidate(_lasso_anchors, false)
			return true
		# An anchored candidate owns its frozen Store snapshot until it is
		# confirmed, corrected, cancelled, or replaced by another tool.
		return true
	if _active_tool == &"subtract" and _session.tool_id == &"subtract" and _session.phase != EDIT_SESSION.IDLE:
		if key == KEY_SPACE:
			return _commit_pointer_subtract_with_space()
		return true
	if _add_pointer_mode or _is_pointer_drag():
		return true
	if _drag_kind == "keyboard_add":
		return _handle_keyboard_add_key(event, key)
	if key == KEY_BRACKETLEFT or key == KEY_BRACKETRIGHT:
		_cycle_selection(-1 if key == KEY_BRACKETLEFT else 1)
		return true
	if not event.ctrl_pressed and not event.alt_pressed:
		match key:
			KEY_V:
				set_active_tool(&"select")
				return true
			KEY_S:
				return _begin_keyboard_spatial(&"subtract")
			KEY_L:
				var region := _find_region(_record_for_frame(_current_frame()), _selected_region_id())
				if REGION_GEOMETRY.canonical_shape(region) == REGION_GEOMETRY.SHAPE_POLYGON:
					set_active_tool(&"lasso")
					_report("Lasso vertices: drag points; double-click an edge to insert; [ / ] select; arrows move; Insert adds; Delete removes; Escape exits")
					return true
				return _begin_keyboard_spatial(&"lasso")
			KEY_F:
				return _begin_keyboard_spatial(&"fill")
			KEY_P:
				return _begin_keyboard_spatial(&"eraser" if event.shift_pressed else &"paint")
	if key == KEY_A and not event.ctrl_pressed and not event.alt_pressed:
		_begin_keyboard_add()
		return true
	if _active_tool == &"select" and (key == KEY_DELETE or key == KEY_BACKSPACE):
		delete_selected()
		return true
	if _active_tool != &"select":
		return false
	var direction := _arrow_direction(key)
	if direction == Vector2.ZERO:
		return false
	var frame := _current_frame()
	var region_id := _selected_region_id()
	var record := _record_for_frame(frame)
	if frame < 0 or region_id.is_empty() or record.is_empty():
		_report("Select a region before editing it")
		return true
	var image_size := _current_image_size()
	if image_size == Vector2.ZERO:
		_report("Current frame has no valid image size")
		return true
	var step := _key_step(event)
	var command: Variant
	if event.alt_pressed:
		var region := _find_region(record, region_id)
		if region.is_empty():
			_report("Select a region before resizing it")
			return true
		if REGION_GEOMETRY.canonical_shape(region) == REGION_GEOMETRY.SHAPE_POLYGON:
			var points := _region_polygon(region)
			var bounds: Rect2 = POLYGON_OPS.polygon_bounds(points)
			var resized: PackedVector2Array = POLYGON_OPS.resize_by_handle(
				points,
				4,
				bounds.end + direction * step,
			)
			command = REPLACE_GEOMETRY_COMMAND.new(frame, record, region_id, resized, image_size)
		elif REGION_GEOMETRY.canonical_shape(region) == REGION_GEOMETRY.SHAPE_BOX:
			var box: Array = region["box"].duplicate(true)
			box[2] = float(box[2]) + direction.x * step
			box[3] = float(box[3]) + direction.y * step
			command = RESIZE_COMMAND.new(frame, record, region_id, box, image_size)
		else:
			_report("The selected region has no editable geometry")
			return true
	else:
		command = MOVE_COMMAND.new(frame, record, region_id, direction * step, image_size)
	_execute(command, frame)
	return true


func begin_add_box() -> void:
	if not _active:
		return
	if _session.has_pending_class_assignment():
		_report("Choose a class and kind, or press Escape to discard the pending region")
		return
	if _session.has_working_mask():
		_report("Finish the Fill contour or press Escape")
		return
	cancel()
	_active_tool = &"box"
	_add_pointer_mode = true
	_report("Drag to create a box; press Escape to cancel")


func cancel() -> void:
	if not _active:
		_clear_transient()
		return
	var keep_vertex_mode := _vertex_mode_requested
	_clear_transient()
	_vertex_mode_requested = keep_vertex_mode
	_show_idle_brush_cursor()


func _await_class_for_box(frame: int, before: Dictionary, box: Array, image_size: Vector2) -> void:
	_candidate_token += 1
	_session.begin(&"box", frame, "", before)
	_session.set_awaiting_class(
		{"shape": &"box", "box": box.duplicate(true)},
		image_size,
		_candidate_token,
		"Choose a class and kind",
	)
	_push_session_overlay()
	if _request_class_assignment.is_valid():
		_request_class_assignment.call(_session.pending_request())
	else:
		_report("Class assignment is unavailable; press Escape to discard the pending region")


func _await_class_for_polygon(
	frame: int,
	before: Dictionary,
	polygon: PackedVector2Array,
	image_size: Vector2,
	tool_id: StringName,
) -> void:
	_candidate_token += 1
	_session.begin(tool_id, frame, "", before)
	_session.set_awaiting_class(
		{"shape": &"polygon", "polygon": polygon.duplicate()},
		image_size,
		_candidate_token,
		"Choose a class and kind",
	)
	_push_session_overlay()
	if _request_class_assignment.is_valid():
		_request_class_assignment.call(_session.pending_request())
	else:
		_report("Class assignment is unavailable; press Escape to discard the pending region")


func _confirm_pending_region(payload: Dictionary) -> PackedStringArray:
	if not _active:
		return PackedStringArray(["edit plugin is not active"])
	if not _session.has_pending_class_assignment():
		return PackedStringArray(["There is no pending region to confirm"])
	var request: Dictionary = _session.pending_request()
	var token_value: Variant = payload.get("candidate_token")
	if typeof(token_value) != TYPE_INT or int(token_value) != int(request.get("candidate_token", -1)):
		return _pending_confirmation_error("Pending region token is stale")
	var class_value: Variant = payload.get("class")
	if typeof(class_value) != TYPE_STRING or String(class_value).strip_edges().is_empty():
		return _pending_confirmation_error("class: expected a non-empty string")
	var kind_value: Variant = payload.get("kind")
	if typeof(kind_value) != TYPE_STRING or String(kind_value).strip_edges().is_empty():
		return _pending_confirmation_error("kind: expected a non-empty string")
	if _current_frame() != _session.frame:
		return _pending_confirmation_error("Pending region frame is stale")
	var before: Dictionary = _session.before.duplicate(true)
	if before.is_empty() or _record_for_frame(_session.frame) != before:
		return _pending_confirmation_error("Pending region record changed before confirmation")
	var pending: Dictionary = _session._pending_commit_snapshot()
	var geometry: Variant = pending.get("geometry")
	var image_size: Variant = pending.get("image_size")
	if not image_size is Vector2 or not image_size.is_finite() or image_size.x <= 0.0 or image_size.y <= 0.0:
		return _pending_confirmation_error("Pending region has invalid image bounds")
	if not geometry is Dictionary:
		return _pending_confirmation_error("Pending region has invalid geometry")
	var frame: int = int(_session.frame)
	var shape := StringName(geometry.get("shape", &""))
	var command: Variant
	if shape == &"box":
		var box: Variant = geometry.get("box")
		if not box is Array or box.size() != 4:
			return _pending_confirmation_error("Pending region has invalid Box geometry")
		var region := {"box": box.duplicate(true)}
		if REGION_GEOMETRY.canonical_shape(region) != REGION_GEOMETRY.SHAPE_BOX:
			return _pending_confirmation_error("Pending region has invalid Box geometry")
		if not REGION_GEOMETRY.fits_image(region, image_size):
			return _pending_confirmation_error("Pending region geometry must stay inside the current image")
		command = ADD_COMMAND.new(
			frame,
			before,
			box.duplicate(true),
			String(class_value).strip_edges(),
			String(kind_value).strip_edges(),
			image_size,
		)
	elif shape == &"polygon":
		var polygon: Variant = geometry.get("polygon")
		if (
			not polygon is PackedVector2Array
			or not POLYGON_OPS.validate_simple_polygon(polygon)
			or not POLYGON_OPS.points_fit_image(polygon, image_size)
		):
			return _pending_confirmation_error("Pending region has invalid Polygon geometry")
		command = ADD_POLYGON_COMMAND.new(
			frame,
			before,
			polygon.duplicate(),
			String(class_value).strip_edges(),
			String(kind_value).strip_edges(),
			image_size,
		)
	else:
		return _pending_confirmation_error("Pending region has invalid geometry shape")
	var errors: PackedStringArray = _history.execute(command, _store)
	if not errors.is_empty():
		_report_errors(errors)
		return errors
	var continue_lasso_vertices: bool = _session.tool_id == &"lasso"
	_clear_transient()
	_vertex_mode_requested = continue_lasso_vertices
	_refresh_visible_frame(frame)
	_select_added_if_still_current(frame, command.get_region_id())
	refresh_edit_overlay()
	_show_idle_brush_cursor()
	return PackedStringArray()


func _cancel_pending_region(payload: Dictionary) -> PackedStringArray:
	if not _active:
		return PackedStringArray(["edit plugin is not active"])
	if not _session.has_pending_class_assignment():
		return PackedStringArray(["There is no pending region to cancel"])
	var request: Dictionary = _session.pending_request()
	var token_value: Variant = payload.get("candidate_token")
	if typeof(token_value) != TYPE_INT or int(token_value) != int(request.get("candidate_token", -1)):
		return _pending_confirmation_error("Pending region token is stale")
	_clear_transient()
	return PackedStringArray()


func _pending_confirmation_error(message_text: String) -> PackedStringArray:
	var errors := PackedStringArray([message_text])
	_report_errors(errors)
	return errors


func relabel_selected(class_label: String, kind: Variant = null) -> PackedStringArray:
	return _execute_selected(RELABEL_COMMAND, class_label, false, kind)


func set_selected_track_id(track_id: Variant) -> PackedStringArray:
	return _execute_selected(TRACK_COMMAND, track_id)


func set_selected_fill(filled: bool) -> PackedStringArray:
	return _execute_selected(FILL_COMMAND, filled)


func set_selected_geometry(box: Array) -> PackedStringArray:
	return _execute_selected(RESIZE_COMMAND, box.duplicate(true), true)


func delete_selected() -> PackedStringArray:
	if not _active:
		return PackedStringArray(["edit plugin is not active"])
	if _session.has_working_mask():
		var working_errors := PackedStringArray(["Finish the Fill contour or press Escape"])
		_report_errors(working_errors)
		return working_errors
	if _has_transient_edit():
		cancel()
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


func _handle_lasso_pointer(event: InputEvent, image_position: Vector2) -> void:
	if _session.has_working_mask():
		return
	if event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if event.pressed:
			_lasso_pointer_pressed(event, image_position)
		else:
			_lasso_pointer_released(image_position)
		return
	if event is InputEventMouseMotion and not _lasso_mode.is_empty():
		_lasso_pointer_moved(event, image_position)


func _lasso_pointer_pressed(event: InputEventMouseButton, image_position: Vector2) -> void:
	if _lasso_mode.is_empty():
		var frame := _current_frame()
		var record := _record_for_frame(frame)
		var image_size := _current_image_size()
		if frame < 0 or record.is_empty():
			return
		if image_size == Vector2.ZERO:
			_report("Current frame has no valid image size")
			return
		_drag_frame = frame
		_drag_before = record.duplicate(true)
		_drag_image_size = image_size
		_drag_start = image_position
		_drag_kind = "lasso"
		_lasso_mode = &"press"
		_lasso_press_position = image_position
		_lasso_anchors = PackedVector2Array()
		_lasso_invalid_message = ""
		_stroke_points = PackedVector2Array([image_position])
		_session.begin(&"lasso", frame, "", record)
		_set_drawing_overlay(_stroke_points, image_position, 0.0)
		return
	if _lasso_mode not in [&"anchors", &"invalid", &"anchor_press"]:
		return
	if _drag_frame != _current_frame() or _drag_before.is_empty():
		cancel()
		_report("Lasso cancelled because the current frame changed")
		return
	if event.double_click:
		_append_lasso_anchor(image_position)
		var succeeded := _finish_lasso_candidate(_lasso_anchors, false)
		if not succeeded:
			_lasso_release_suppressed = true
		return
	var hit_anchor := _lasso_anchor_at(image_position)
	if hit_anchor >= 0:
		_lasso_active_anchor = hit_anchor
		_lasso_press_position = image_position
		_lasso_vertex_moved = false
		_lasso_mode = &"vertex_drag"
		_show_lasso_anchor_preview(image_position, false)
		return
	_lasso_press_position = image_position
	_lasso_mode = &"anchor_press"
	_show_lasso_anchor_preview(image_position)


func _lasso_pointer_moved(event: InputEventMouseMotion, image_position: Vector2) -> void:
	match _lasso_mode:
		&"vertex_drag":
			if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
				if not image_position.is_equal_approx(_lasso_press_position):
					_lasso_vertex_moved = true
				if _lasso_vertex_moved:
					_lasso_anchors[_lasso_active_anchor] = image_position
					_show_lasso_anchor_preview(image_position, false)
		&"press":
			if event.button_mask & MOUSE_BUTTON_MASK_LEFT == 0:
				return
			if _lasso_press_position.distance_to(image_position) > LASSO_DRAG_THRESHOLD_IMAGE_PX:
				_lasso_mode = &"freehand"
				_append_stroke_point(image_position)
				_show_lasso_freehand_preview(image_position)
			else:
				_set_drawing_overlay(PackedVector2Array([_lasso_press_position]), image_position, 0.0)
		&"freehand":
			if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
				_append_stroke_point(image_position)
				_show_lasso_freehand_preview(image_position)
		&"anchors", &"invalid", &"anchor_press":
			_show_lasso_anchor_preview(image_position)


func _lasso_pointer_released(image_position: Vector2) -> void:
	if _lasso_release_suppressed:
		_lasso_release_suppressed = false
		return
	match _lasso_mode:
		&"vertex_drag":
			if _lasso_vertex_moved or not image_position.is_equal_approx(_lasso_press_position):
				_lasso_anchors[_lasso_active_anchor] = image_position
			_lasso_mode = &"anchors"
			_show_lasso_anchor_preview(image_position, false)
		&"press":
			if _lasso_press_position.distance_to(image_position) > LASSO_DRAG_THRESHOLD_IMAGE_PX:
				_lasso_mode = &"freehand"
				_append_stroke_point(image_position)
				_finish_lasso_candidate(_stroke_points, true)
				return
			_lasso_anchors = PackedVector2Array([_lasso_press_position])
			_lasso_active_anchor = 0
			_lasso_mode = &"anchors"
			_drag_kind = ""
			_show_lasso_anchor_preview(_lasso_press_position)
			_report("Lasso: click contour points; drag a point to adjust; Space or double-click closes")
		&"freehand":
			_append_stroke_point(image_position)
			_finish_lasso_candidate(_stroke_points, true)
		&"anchor_press":
			_append_lasso_anchor(_lasso_press_position)
			_lasso_mode = &"anchors"
			_drag_kind = ""
			_show_lasso_anchor_preview(_lasso_press_position)


func _append_lasso_anchor(point: Vector2) -> void:
	if _lasso_anchors.size() >= MAX_GESTURE_POINTS:
		return
	if _lasso_anchors.is_empty() or not _lasso_anchors[-1].is_equal_approx(point):
		_lasso_anchors.append(point)
		_lasso_active_anchor = _lasso_anchors.size() - 1


func _lasso_anchor_at(point: Vector2) -> int:
	var transform: Variant = _viewport.get_image_transform()
	var cursor: Vector2 = transform.image_to_viewport(point)
	var best := -1
	var distance := HANDLE_TOLERANCE_VIEWPORT_PX
	for index in range(_lasso_anchors.size()):
		var candidate: float = cursor.distance_to(transform.image_to_viewport(_lasso_anchors[index]))
		if candidate <= distance:
			best = index
			distance = candidate
	return best


func _edit_lasso_anchor_key(event: InputEventKey, key: Key) -> bool:
	if _lasso_anchors.is_empty():
		return false
	_lasso_active_anchor = clampi(_lasso_active_anchor, 0, _lasso_anchors.size() - 1)
	if key in [KEY_BRACKETLEFT, KEY_BRACKETRIGHT]:
		_lasso_active_anchor = posmod(_lasso_active_anchor + (-1 if key == KEY_BRACKETLEFT else 1), _lasso_anchors.size())
	elif key == KEY_DELETE:
		_lasso_anchors.remove_at(_lasso_active_anchor)
		_lasso_active_anchor = mini(_lasso_active_anchor, _lasso_anchors.size() - 1)
	elif _arrow_direction(key) != Vector2.ZERO and not event.alt_pressed:
		var moved := _lasso_anchors[_lasso_active_anchor] + _arrow_direction(key) * _key_step(event)
		if not POLYGON_OPS.points_fit_image(PackedVector2Array([moved]), _drag_image_size):
			_report("Lasso vertex refused: point must stay inside the current image")
			return true
		_lasso_anchors[_lasso_active_anchor] = moved
	else:
		return false
	_show_lasso_anchor_preview(_lasso_anchors[_lasso_active_anchor] if _lasso_active_anchor >= 0 else Vector2.ZERO, false)
	return true


func _show_lasso_anchor_preview(cursor: Vector2, append_cursor := true) -> void:
	var path := _lasso_anchors.duplicate()
	if append_cursor and not path.is_empty() and not path[-1].is_equal_approx(cursor) and path.size() < MAX_GESTURE_POINTS:
		path.append(cursor)
	var ring := POLYGON_OPS.sanitize_freehand(path, 0.0, 0.0)
	if not ring.is_empty() and POLYGON_OPS.points_fit_image(path, _drag_image_size):
		_session.set_candidate(ring, "Lasso candidate ready", EDIT_SESSION.CANDIDATE_COLOR, path, cursor)
		_push_session_overlay()
		return
	if not _lasso_invalid_message.is_empty():
		_session.set_invalid(
			_bounded_preview_points(path),
			_lasso_invalid_message,
			{},
			EDIT_SESSION.INVALID_COLOR,
			_lasso_anchors,
		)
		_push_session_overlay()
		return
	_set_drawing_overlay(_bounded_preview_points(path), cursor, 0.0)


func _show_lasso_freehand_preview(cursor: Vector2) -> void:
	var path := _bounded_preview_points(_stroke_points)
	var ring := PackedVector2Array()
	var close_distance := _stroke_close_distance(_stroke_points, true)
	if (
		_stroke_points.size() >= 3
		and close_distance >= 0.0
		and POLYGON_OPS.points_fit_image(_stroke_points, _drag_image_size)
	):
		ring = POLYGON_OPS.sanitize_freehand(
			_stroke_points,
			FREEHAND_SIMPLIFY_TOLERANCE,
			close_distance,
		)
	if not ring.is_empty():
		_session.set_candidate(ring, "Lasso candidate ready", EDIT_SESSION.CANDIDATE_COLOR, path, cursor)
		_push_session_overlay()
		return
	_set_drawing_overlay(path, cursor, 0.0)


func _remove_lasso_anchor() -> void:
	if not _lasso_anchors.is_empty():
		_lasso_anchors.remove_at(_lasso_anchors.size() - 1)
	_lasso_active_anchor = mini(_lasso_active_anchor, _lasso_anchors.size() - 1)
	_lasso_mode = &"anchors"
	_drag_kind = ""
	var cursor := _lasso_anchors[-1] if not _lasso_anchors.is_empty() else Vector2.ZERO
	_show_lasso_anchor_preview(cursor)
	_report("Lasso anchor removed")


func _begin_pointer_drag(event: InputEventMouseButton, image_position: Vector2) -> void:
	if _session.has_working_mask() and _active_tool != &"fill":
		return
	if _drag_kind == "keyboard_add" or _is_pointer_drag():
		cancel()
	var frame := _current_frame()
	var record := _record_for_frame(frame)
	if frame < 0 or record.is_empty():
		return
	_drag_image_size = _current_image_size()
	if _active_tool in [&"box", &"lasso", &"fill", &"subtract", &"paint", &"eraser", &"select"] and _drag_image_size == Vector2.ZERO:
		_report("Current frame has no valid image size")
		return
	if _active_tool == &"box":
		_add_pointer_mode = false
		_drag_kind = "add"
		_drag_frame = frame
		_drag_start = image_position
		_drag_before = record.duplicate(true)
		_session.begin(&"box", frame, "", record)
		_set_geometry_preview_overlay(PackedVector2Array([image_position]), image_position, 0.0, _drag_image_size)
		return
	var hit := _hit_test(record, image_position)
	if _active_tool == &"fill":
		_fill_at_point(frame, record, image_position, _drag_image_size)
		return
	if _active_tool in [&"paint", &"eraser"]:
		var brush_region_id := _selected_region_id()
		if not brush_region_id.is_empty() and _find_region(record, brush_region_id).is_empty():
			brush_region_id = ""
		_drag_kind = String(_active_tool)
		_drag_frame = frame
		_drag_region_id = brush_region_id
		_drag_start = image_position
		_drag_before = record.duplicate(true)
		_stroke_points = PackedVector2Array([image_position])
		if not _begin_brush(_active_tool, frame, record, brush_region_id, image_position):
			_clear_transient()
		return
	if _active_tool == &"subtract":
		var operation_region_id := _selected_region_id()
		if not operation_region_id.is_empty() and _find_region(record, operation_region_id).is_empty():
			operation_region_id = ""
		_begin_freehand_drag(frame, record, _active_tool, operation_region_id, image_position)
		return
	if _active_tool != &"select":
		return
	var selected_id := _selected_region_id()
	var selected_region := _find_region(record, selected_id)
	if not selected_region.is_empty():
		var selected_handle := _region_handle_at(selected_region, event.position)
		if selected_handle >= 0:
			_drag_kind = "resize"
			_resize_handle = selected_handle
			_drag_frame = frame
			_drag_region_id = selected_id
			_drag_start = image_position
			_drag_before = record.duplicate(true)
			_session.begin(&"select", frame, selected_id, record)
			return
	if hit.is_empty():
		_set_selected_region("")
		return
	var region_id := str(hit.get("id", ""))
	_set_selected_region(region_id)
	_drag_kind = "move"
	_resize_handle = -1
	_resize_handle = _region_handle_at(hit, event.position)
	if _resize_handle >= 0:
		_drag_kind = "resize"
	_drag_frame = frame
	_drag_region_id = region_id
	_drag_start = image_position
	_drag_before = record.duplicate(true)
	_session.begin(&"select", frame, region_id, record)


func _begin_freehand_drag(
	frame: int,
	record: Dictionary,
	kind: StringName,
	region_id: String,
	image_position: Vector2,
) -> void:
	_drag_kind = String(kind)
	_drag_frame = frame
	_drag_region_id = region_id
	_drag_start = image_position
	_drag_before = record.duplicate(true)
	_stroke_points = PackedVector2Array([image_position])
	_session.begin(kind, frame, region_id, record)
	if kind == &"lasso":
		_set_geometry_preview_overlay(_stroke_points, image_position, 0.0, _drag_image_size)
	else:
		_set_drawing_overlay(_stroke_points, image_position, 0.0)


func _begin_brush(
	tool_id: StringName,
	frame: int,
	record: Dictionary,
	region_id: String,
	point: Vector2,
) -> bool:
	var raster_size := Vector2i(roundi(_drag_image_size.x), roundi(_drag_image_size.y))
	var buffer_errors: PackedStringArray = _brush_buffer.begin(_brush_radius_image_px, raster_size)
	_buffered_points = 0
	_brush_error = ""
	if not buffer_errors.is_empty():
		_report_errors(buffer_errors)
		return false
	_cache_brush_regions(record, raster_size)
	_session.begin(tool_id, frame, region_id, record)
	_update_brush_preview(tool_id, PackedVector2Array([point]), point)
	return true


func _update_brush_preview(
	tool_id: StringName,
	stroke: PackedVector2Array,
	cursor: Vector2,
) -> void:
	if _drag_image_size == Vector2.ZERO:
		return
	var stroke_mask := _buffered_stroke(stroke)
	var result := {}
	var target_id := _drag_region_id if _keyboard_tool.is_empty() else _keyboard_region_id
	if tool_id == &"paint":
		var operation := _paint_operation(stroke_mask, target_id)
		if bool(operation.get("ok", false)):
			result = operation.get("result", {})
			target_id = str(operation.get("target_id", ""))
		else:
			result = stroke_mask.duplicate(true)
			result["ok"] = false
			result["message"] = str(operation.get("message", "Paint overlaps multiple regions."))
	else:
		var operation := _eraser_operation(stroke_mask)
		if bool(operation.get("ok", false)):
			_session.region_id = ""
			_session.set_brush_preview({}, cursor, _brush_radius_image_px, _brush_overlay_color(tool_id))
			_session.set_batch_brush_preview(operation.regions)
			_push_session_overlay()
			return
		result = stroke_mask.duplicate(true)
		result["ok"] = false
		result["message"] = operation.message
		target_id = ""
	_session.region_id = target_id
	var valid := bool(result.get("ok", false))
	var message := "" if valid else "%s preview refused: %s" % [
		_brush_label(tool_id),
		result.get("message", "the result mask is invalid"),
	]
	_session.set_brush_preview(
		result,
		cursor,
		_brush_radius_image_px,
		_brush_overlay_color(tool_id),
		message,
		not valid,
	)
	_push_session_overlay()
	if not valid:
		_report(message)


func _buffered_stroke(stroke: PackedVector2Array) -> Dictionary:
	if _brush_error.is_empty():
		for index in range(_buffered_points, stroke.size()):
			var errors: PackedStringArray = _brush_buffer.append_point(stroke[index])
			if not errors.is_empty():
				_brush_error = errors[0]
				break
			_buffered_points += 1
	var snapshot: Dictionary = _brush_buffer.snapshot()
	snapshot["ok"] = _brush_error.is_empty() and not snapshot.mask.is_empty()
	snapshot["message"] = _brush_error if not _brush_error.is_empty() else "The clipped stroke has no selected pixels"
	return snapshot


func _cache_brush_regions(record: Dictionary, raster_size: Vector2i) -> void:
	_brush_region_masks.clear()
	var regions: Variant = record.get("regions", [])
	if not regions is Array:
		return
	for value: Variant in regions:
		if not value is Dictionary:
			continue
		var polygon := _region_polygon(value)
		var region_id := str(value.get("id", ""))
		if region_id.is_empty() or polygon.is_empty():
			continue
		var roi := MASK_REGION_OPS._point_bounds(polygon, 0.0, raster_size)
		var allocation := MASK_REGION_OPS._allocation_error(roi)
		_brush_region_masks.append({"id": region_id, "mask": {}, "polygon": polygon,
			"roi": roi, "image_size": raster_size, "error": str(allocation.get("message", ""))})


func _eraser_operation(stroke_mask: Dictionary) -> Dictionary:
	if not bool(stroke_mask.get("ok", false)):
		return {"ok": false, "message": stroke_mask.get("message", "Invalid Eraser stroke")}
	var affected: Array[Dictionary] = []
	for entry: Dictionary in _brush_region_masks:
		if not entry.roi.intersects(stroke_mask.roi):
			continue
		if not str(entry.error).is_empty():
			return {"ok": false, "message": "Region %s: %s" % [entry.id, entry.error]}
		if entry.mask.is_empty():
			entry.mask = MASK_REGION_OPS.rasterize_polygon_mask(entry.polygon, entry.image_size)
		if not bool(entry.mask.get("ok", false)):
			return {"ok": false, "message": "Region %s: %s" % [entry.id, entry.mask.get("message", "Invalid geometry")]}
		if not MASK_REGION_OPS.masks_overlap(entry.mask, stroke_mask):
			continue
		var result := MASK_REGION_OPS.combine_masks(entry.mask, stroke_mask, &"subtract")
		if not bool(result.get("ok", false)):
			return {"ok": false, "message": "Region %s: %s" % [entry.id, result.get("message", "Invalid mask")]}
		affected.append({"id": entry.id, "mask": result})
	return {"ok": true, "regions": affected}


func _paint_operation(stroke_mask: Dictionary, preferred_region_id: String) -> Dictionary:
	if not bool(stroke_mask.get("ok", false)):
		return {"ok": false, "message": stroke_mask.get("message", "Paint stroke is invalid")}
	var overlaps: Array[Dictionary] = []
	for entry: Dictionary in _brush_region_masks:
		var relevant: bool = entry.roi.intersects(stroke_mask.roi)
		if not str(entry.error).is_empty() and (relevant or entry.id == preferred_region_id):
			return {"ok": false, "message": "Region %s: %s" % [entry.id, entry.error]}
		if not relevant:
			continue
		if entry.mask.is_empty():
			entry.mask = MASK_REGION_OPS.rasterize_polygon_mask(entry.polygon, entry.image_size)
			if not bool(entry.mask.get("ok", false)):
				entry.error = str(entry.mask.get("message", "Region cannot be rasterized safely"))
				return {"ok": false, "message": "Region %s: %s" % [entry.id, entry.error]}
		if MASK_REGION_OPS.masks_overlap(entry.mask, stroke_mask):
			overlaps.append(entry)
	if overlaps.is_empty():
		return {"ok": true, "mode": &"new", "target_id": "", "result": stroke_mask.duplicate(true)}
	var target: Dictionary = {}
	if not preferred_region_id.is_empty():
		for entry: Dictionary in overlaps:
			if str(entry.get("id", "")) == preferred_region_id:
				target = entry
				break
	if target.is_empty() and overlaps.size() == 1:
		target = overlaps[0]
	if target.is_empty():
		return {"ok": false, "message": "Paint overlaps multiple regions; select the intended region and try again."}
	var result := MASK_REGION_OPS.combine_masks(target.get("mask", {}), stroke_mask, &"union")
	return {
		"ok": bool(result.get("ok", false)),
		"mode": &"repair",
		"target_id": str(target.get("id", "")),
		"subject": target.get("polygon", PackedVector2Array()),
		"result": result,
		"message": result.get("message", "Paint union failed"),
	}


func _fill_at_point(
	frame: int,
	before: Dictionary,
	seed: Vector2,
	image_size: Vector2,
) -> void:
	var raster_size := Vector2i(roundi(image_size.x), roundi(image_size.y))
	var uses_working_mask := _session.has_working_mask()
	var boundary: Dictionary = _session.working_mask.duplicate(true) if uses_working_mask else _record_boundary_mask(before, raster_size)
	if uses_working_mask and (_session.frame != frame or _session.before != before):
		var stale_message := "Fill refused: the frame changed after the Paint outline; press Escape and draw it again."
		_session.set_working_mask(boundary, stale_message)
		_push_session_overlay()
		_report(stale_message)
		return
	var result := FILL_SOLVER.solve(boundary, seed, raster_size, _fill_gap_radius, uses_working_mask)
	if bool(result.get("requires_confirmation", false)):
		if not uses_working_mask:
			_session.begin(&"fill", frame, "", before)
		_session.set_fill_repair(result, seed)
		_push_session_overlay()
		_report(str(result.message))
		return
	_accept_fill_result(result, frame, before, seed, image_size, uses_working_mask, boundary)


func _confirm_fill_repair() -> PackedStringArray:
	if not _session.has_fill_repair():
		return PackedStringArray(["No Fill repair is awaiting confirmation"])
	if _current_frame() != _session.frame or _record_for_frame(_session.frame) != _session.before:
		var errors := PackedStringArray(["Fill refused: the frame changed during repair preview; cancel and retry"])
		_report_errors(errors)
		return errors
	var seed: Vector2 = _session.cursor
	var result: Dictionary = _session.take_fill_repair()
	_accept_fill_result(result, _session.frame, _session.before, seed, _current_image_size(),
		_session.has_working_mask(), _session.working_mask)
	return PackedStringArray()


func _accept_fill_result(result: Dictionary, frame: int, before: Dictionary, seed: Vector2,
	image_size: Vector2, uses_working_mask: bool, boundary: Dictionary) -> void:
	if StringName(result.get("status", &"")) == MASK_REGION_OPS.STATUS_SINGLE:
		var polygon: PackedVector2Array = result.get("polygon", PackedVector2Array())
		_await_class_for_polygon(frame, before, polygon, image_size, &"fill")
		return
	if uses_working_mask and StringName(result.get("status", &"")) == MASK_REGION_OPS.STATUS_HOLE:
		var continue_message := "Filled one enclosed area; fill the next blank area (F, arrows, Enter). Ctrl+Z undoes this fill."
		_session.set_working_mask(result, continue_message)
		_session.set_working_cursor(seed)
		_push_session_overlay()
		_report(continue_message)
		return
	var message := "Fill refused: %s" % result.get("message", "No closed region was found around the selected blank area.")
	if uses_working_mask:
		_session.set_working_mask(boundary, "%s The Paint outline is still available; choose another seed or press Escape." % message)
		_session.set_working_cursor(seed)
	else:
		_session.begin(&"fill", frame, "", before)
		_session.set_invalid(PackedVector2Array([seed]), message)
	_push_session_overlay()
	_report(message)


func _record_boundary_mask(record: Dictionary, raster_size: Vector2i) -> Dictionary:
	var combined := {"roi": Rect2i(), "mask": PackedByteArray()}
	var regions: Variant = record.get("regions", [])
	if not regions is Array:
		return combined
	for value: Variant in regions:
		if not value is Dictionary:
			continue
		var polygon := _region_polygon(value)
		if polygon.is_empty():
			continue
		var mask := MASK_REGION_OPS.rasterize_polygon_mask(polygon, raster_size)
		if not bool(mask.get("ok", false)):
			return mask
		combined = MASK_REGION_OPS.combine_masks(combined, mask, &"union")
		if not bool(combined.get("ok", false)):
			return combined
	return combined


func _update_pointer_preview(image_position: Vector2) -> void:
	if _drag_before.is_empty():
		return
	if _drag_kind in ["lasso", "subtract", "paint", "eraser"]:
		_append_stroke_point(image_position)
	if _drag_kind in ["paint", "eraser"]:
		_update_brush_preview(StringName(_drag_kind), _stroke_points, image_position)
		return
	var path := PackedVector2Array()
	var radius := 0.0
	match _drag_kind:
		"move", "resize":
			path = _selection_preview_path(image_position)
		"add":
			path = _box_path(_normalized_box(_drag_start, image_position))
		"lasso", "subtract":
			path = _bounded_preview_points(_stroke_points)
		_:
			return
	if _drag_kind in ["move", "resize", "add", "lasso"]:
		_set_geometry_preview_overlay(path, image_position, radius, _drag_image_size)
	else:
		_set_drawing_overlay(path, image_position, radius, _brush_overlay_color(StringName(_drag_kind)))


func _finish_pointer_drag(image_position: Vector2) -> void:
	if _drag_kind.is_empty() or _drag_kind == "keyboard_add":
		return
	var kind := _drag_kind
	var frame := _drag_frame
	var region_id := _drag_region_id
	var before := _drag_before.duplicate(true)
	var start := _drag_start
	var handle := _resize_handle
	var image_size := _drag_image_size
	var stroke := _stroke_points.duplicate()
	if kind in ["lasso", "subtract", "paint", "eraser"]:
		if (
			stroke.size() < MAX_GESTURE_POINTS
			and (stroke.is_empty() or stroke[-1].distance_squared_to(image_position) > 0.000001)
		):
			stroke.append(image_position)
	if kind not in ["subtract", "paint", "eraser"]:
		_clear_transient()
	var command: Variant
	match kind:
		"move":
			var delta := image_position - start
			if delta.is_zero_approx():
				_refresh_visible_frame(frame)
				return
			command = MOVE_COMMAND.new(frame, before, region_id, delta, image_size)
		"resize":
			var region := _find_region(before, region_id)
			if REGION_GEOMETRY.canonical_shape(region) == REGION_GEOMETRY.SHAPE_POLYGON:
				var old_polygon := _region_polygon(region)
				var resized_polygon: PackedVector2Array = POLYGON_OPS.resize_by_handle(old_polygon, handle, image_position)
				if resized_polygon.is_empty() or resized_polygon == old_polygon:
					_refresh_visible_frame(frame)
					return
				command = REPLACE_GEOMETRY_COMMAND.new(frame, before, region_id, resized_polygon, image_size)
			else:
				var box := _resized_box(region.get("box", []), handle, image_position)
				if _numeric_arrays_approx_equal(box, region.get("box", [])):
					_refresh_visible_frame(frame)
					return
				command = RESIZE_COMMAND.new(frame, before, region_id, box, image_size)
		"add":
			_await_class_for_box(frame, before, _normalized_box(start, image_position), image_size)
			return
		"subtract":
			_commit_region_stroke(StringName(kind), frame, before, region_id, stroke, image_size)
			return
		"paint", "eraser":
			_commit_brush_stroke(StringName(kind), frame, before, region_id, stroke, image_size)
			_show_idle_brush_cursor()
			return
	_execute(command, frame)


func _begin_keyboard_spatial(tool_id: StringName) -> bool:
	if _session.has_working_mask():
		if not set_active_tool(tool_id).is_empty():
			return true
		_keyboard_tool = &"fill"
		_keyboard_frame = _session.frame
		_keyboard_before = _session.before.duplicate(true)
		_keyboard_region_id = ""
		_drag_image_size = _current_image_size()
		_keyboard_cursor = Vector2(_session.working_mask.roi.position) + Vector2(_session.working_mask.roi.size) * 0.5
		_keyboard_points = PackedVector2Array([_keyboard_cursor])
		_show_keyboard_fill_preview()
		return true
	cancel()
	var frame := _current_frame()
	var record := _record_for_frame(frame)
	if frame < 0 or record.is_empty():
		_report("Cannot start %s without a current frame" % tool_id)
		return true
	var image_size := _current_image_size()
	if image_size == Vector2.ZERO:
		_report("Current frame has no valid image size")
		return true
	var region_id := _selected_region_id()
	if not region_id.is_empty() and _find_region(record, region_id).is_empty():
		region_id = ""
	var errors := set_active_tool(tool_id)
	if not errors.is_empty():
		return true
	_drag_image_size = image_size
	_keyboard_tool = tool_id
	_keyboard_frame = frame
	_keyboard_region_id = region_id
	_keyboard_before = record.duplicate(true)
	_keyboard_cursor = _keyboard_start_cursor(record, "" if tool_id == &"fill" else region_id)
	_keyboard_points = PackedVector2Array([_keyboard_cursor])
	if tool_id in [&"paint", &"eraser"]:
		if not _begin_brush(tool_id, frame, record, region_id, _keyboard_cursor):
			_clear_transient()
			return true
	else:
		_session.begin(tool_id, frame, region_id, record)
		_show_keyboard_spatial_preview()
	if tool_id in [&"lasso", &"subtract"]:
		_report("Keyboard %s: arrows draw, Space closes, Escape cancels" % tool_id)
	else:
		_report("Keyboard %s: arrows draw/move, Enter confirms, Escape cancels" % tool_id)
	return true


func _handle_keyboard_spatial_key(event: InputEventKey, key: Key) -> bool:
	if key == KEY_TAB:
		return false
	if key == KEY_BACKSPACE and _keyboard_tool in [&"lasso", &"subtract"]:
		if not _keyboard_points.is_empty():
			_keyboard_points.remove_at(_keyboard_points.size() - 1)
		if not _keyboard_points.is_empty():
			_keyboard_cursor = _keyboard_points[-1]
		_show_keyboard_spatial_preview()
		_report("%s point removed" % ("Lasso" if _keyboard_tool == &"lasso" else "Subtract"))
		return true
	if key == KEY_SPACE and _keyboard_tool in [&"lasso", &"subtract"]:
		var tool_id := _keyboard_tool
		var frame := _keyboard_frame
		var before := _keyboard_before.duplicate(true)
		var region_id := _keyboard_region_id
		var points := _keyboard_points.duplicate()
		var image_size := _drag_image_size
		if tool_id == &"lasso":
			_finalize_lasso(frame, before, points, image_size, false)
		else:
			_commit_region_stroke(tool_id, frame, before, region_id, points, image_size, false)
		return true
	if (key == KEY_ENTER or key == KEY_KP_ENTER):
		if _keyboard_tool in [&"lasso", &"subtract"]:
			return true
		var tool_id := _keyboard_tool
		var frame := _keyboard_frame
		var before := _keyboard_before.duplicate(true)
		var region_id := _keyboard_region_id
		var points := _keyboard_points.duplicate()
		var cursor := _keyboard_cursor
		var image_size := _drag_image_size
		if tool_id == &"fill":
			_fill_at_point(frame, before, cursor, image_size)
		elif tool_id in [&"paint", &"eraser"]:
			_commit_brush_stroke(tool_id, frame, before, region_id, points, image_size)
			_show_idle_brush_cursor()
		else:
			_commit_region_stroke(tool_id, frame, before, region_id, points, image_size, false)
		return true
	var direction := _arrow_direction(key)
	if direction == Vector2.ZERO:
		return true
	var image_size := _drag_image_size
	if image_size.x <= 0.0 or image_size.y <= 0.0:
		_report("Current frame has no valid image size")
		return true
	_keyboard_cursor += direction * _key_step(event)
	_keyboard_cursor.x = clampf(_keyboard_cursor.x, 0.0, image_size.x)
	_keyboard_cursor.y = clampf(_keyboard_cursor.y, 0.0, image_size.y)
	if _keyboard_tool == &"fill":
		_keyboard_points = PackedVector2Array([_keyboard_cursor])
	else:
		_append_keyboard_point(_keyboard_cursor)
	_show_keyboard_spatial_preview()
	return true


func _append_keyboard_point(point: Vector2) -> void:
	if _keyboard_points.size() >= MAX_GESTURE_POINTS:
		return
	if _keyboard_points.is_empty() or not _keyboard_points[-1].is_equal_approx(point):
		_keyboard_points.append(point)


func _show_keyboard_spatial_preview() -> void:
	if _keyboard_before.is_empty():
		return
	if _keyboard_tool in [&"paint", &"eraser"]:
		_update_brush_preview(_keyboard_tool, _keyboard_points, _keyboard_cursor)
		return
	if _keyboard_tool == &"fill":
		_show_keyboard_fill_preview()
		return
	var path := _keyboard_points
	var is_brush := _keyboard_tool in [&"paint", &"eraser"]
	var radius := _brush_radius_image_px if is_brush else 2.0
	var color := _brush_overlay_color(_keyboard_tool) if is_brush else EDIT_SESSION.DRAWING_COLOR
	_set_drawing_overlay(_bounded_preview_points(path), _keyboard_cursor, radius, color)


func _show_keyboard_fill_preview() -> void:
	if _session.has_working_mask():
		_session.set_working_cursor(_keyboard_cursor)
		_push_session_overlay()
		return
	_set_drawing_overlay(PackedVector2Array([_keyboard_cursor]), _keyboard_cursor, 0.0, EDIT_SESSION.WORKING_MASK_COLOR)


func _keyboard_start_cursor(record: Dictionary, region_id: String) -> Vector2:
	var region := _find_region(record, region_id)
	var points := _region_polygon(region)
	if not points.is_empty():
		return POLYGON_OPS.polygon_bounds(points).get_center()
	var transform: Variant = _viewport.get_image_transform()
	if transform is Object and transform.has_method("is_configured") and transform.is_configured():
		return transform.image_size * 0.5
	return Vector2.ZERO


func _begin_keyboard_add() -> void:
	if _session.has_working_mask():
		_report("Finish the Fill contour or press Escape")
		return
	cancel()
	_active_tool = &"box"
	_add_pointer_mode = false
	var frame := _current_frame()
	var record := _record_for_frame(frame)
	if frame < 0 or record.is_empty():
		_report("Cannot add a box without a current frame")
		return
	var transform: Variant = _viewport.get_image_transform()
	if (
		not transform is Object
		or not transform.has_method("is_configured")
		or not transform.is_configured()
	):
		_report("Current frame has no valid image size")
		return
	var dimensions: Vector2 = transform.image_size
	_drag_image_size = dimensions
	_keyboard_box = [0.0, 0.0, minf(20.0, dimensions.x), minf(20.0, dimensions.y)]
	_drag_kind = "keyboard_add"
	_drag_frame = frame
	_drag_before = record.duplicate(true)
	_session.begin(&"box", frame, "", record)
	_show_keyboard_add_preview()
	_report("Keyboard box: arrows move, Alt+arrows resize, Enter confirms, Escape cancels")


func _handle_keyboard_add_key(event: InputEventKey, key: Key) -> bool:
	if key == KEY_ENTER or key == KEY_KP_ENTER:
		var frame := _drag_frame
		var before := _drag_before.duplicate(true)
		var box := _keyboard_box.duplicate(true)
		var image_size := _drag_image_size
		_clear_transient()
		_await_class_for_box(frame, before, box, image_size)
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
	var path := _box_path(_keyboard_box)
	_set_geometry_preview_overlay(path, path[-1] if not path.is_empty() else Vector2.ZERO, 0.0, _drag_image_size)


func _execute_selected(command_script: Script, value: Variant, include_image_size := false, secondary_value: Variant = null) -> PackedStringArray:
	if not _active:
		return PackedStringArray(["edit plugin is not active"])
	if _session.has_working_mask():
		var working_errors := PackedStringArray(["Finish the Fill contour or press Escape"])
		_report_errors(working_errors)
		return working_errors
	if _has_transient_edit():
		cancel()
	var frame := _current_frame()
	var region_id := _selected_region_id()
	var record := _record_for_frame(frame)
	if frame < 0 or region_id.is_empty() or record.is_empty():
		var missing := PackedStringArray(["Select a region before editing it"])
		_report_errors(missing)
		return missing
	var command: Variant
	if include_image_size:
		var image_size := _current_image_size()
		if image_size == Vector2.ZERO:
			var image_errors := PackedStringArray(["Current frame has no valid image size"])
			_report_errors(image_errors)
			return image_errors
		command = command_script.new(frame, record, region_id, value, image_size)
	else:
		command = command_script.new(frame, record, region_id, value, secondary_value) if secondary_value != null else command_script.new(frame, record, region_id, value)
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
		_viewport.set_record(record)


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
		if REGION_GEOMETRY.contains(region, point):
			return region.duplicate(true)
	if not _is_live_object(_viewport) or not _viewport.has_method("get_image_transform"):
		return {}
	var transform: Variant = _viewport.get_image_transform()
	if not transform is Object or not transform.has_method("image_to_viewport"):
		return {}
	var viewport_point: Vector2 = transform.image_to_viewport(point)
	for index in range(regions.size() - 1, -1, -1):
		if not regions[index] is Dictionary:
			continue
		var polygon := _region_polygon(regions[index])
		for edge in range(polygon.size()):
			var start: Vector2 = transform.image_to_viewport(polygon[edge])
			var end: Vector2 = transform.image_to_viewport(polygon[(edge + 1) % polygon.size()])
			var nearest := Geometry2D.get_closest_point_to_segment(viewport_point, start, end)
			if nearest.distance_to(viewport_point) <= EDGE_TOLERANCE_VIEWPORT_PX:
				return regions[index].duplicate(true)
	return {}


func _region_handle_at(region: Dictionary, viewport_point: Vector2) -> int:
	var rect := Rect2()
	if REGION_GEOMETRY.canonical_shape(region) == REGION_GEOMETRY.SHAPE_POLYGON:
		rect = POLYGON_OPS.polygon_bounds(_region_polygon(region))
	elif REGION_GEOMETRY.canonical_shape(region) == REGION_GEOMETRY.SHAPE_BOX:
		var box: Variant = region.get("box")
		if not box is Array or box.size() != 4:
			return -1
		rect = Rect2(float(box[0]), float(box[1]), float(box[2]), float(box[3]))
	else:
		return -1
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return -1
	var transform: Variant = _viewport.get_image_transform()
	if not transform is Object or not transform.has_method("image_to_viewport"):
		return -1
	var center := rect.get_center()
	var handles := [rect.position, Vector2(center.x, rect.position.y), Vector2(rect.end.x, rect.position.y), Vector2(rect.end.x, center.y), rect.end, Vector2(center.x, rect.end.y), Vector2(rect.position.x, rect.end.y), Vector2(rect.position.x, center.y)]
	var nearest := -1
	var distance := HANDLE_TOLERANCE_VIEWPORT_PX
	for index in range(handles.size()):
		var candidate_distance: float = transform.image_to_viewport(handles[index]).distance_to(viewport_point)
		if candidate_distance <= distance:
			distance = candidate_distance
			nearest = index
	return nearest


func _selection_preview_path(point: Vector2) -> PackedVector2Array:
	var region := _find_region(_drag_before, _drag_region_id)
	if region.is_empty():
		return PackedVector2Array()
	if REGION_GEOMETRY.canonical_shape(region) == REGION_GEOMETRY.SHAPE_POLYGON:
		var polygon := _region_polygon(region)
		if _drag_kind == "move":
			var moved := PackedVector2Array()
			var delta := point - _drag_start
			for polygon_point: Vector2 in polygon:
				moved.append(polygon_point + delta)
			polygon = moved
		else:
			polygon = _resize_polygon_preview(polygon, _resize_handle, point)
		return _closed_path(polygon)
	var box: Array = region.get("box", [])
	if _drag_kind == "move" and box.size() == 4:
		box = box.duplicate(true)
		var delta := point - _drag_start
		box[0] = float(box[0]) + delta.x
		box[1] = float(box[1]) + delta.y
	else:
		box = _resized_box(box, _resize_handle, point)
	return _box_path(box)


func _apply_preview_move(record: Dictionary, region_id: String, delta: Vector2) -> void:
	# 仅供已持有脱离快照的几何调用者使用；鼠标移动不再复制或提交帧记录。
	var regions: Variant = record.get("regions", [])
	if not regions is Array:
		return
	for value: Variant in regions:
		if not value is Dictionary or str(value.get("id", "")) != region_id:
			continue
		var region: Dictionary = value
		if REGION_GEOMETRY.canonical_shape(region) == REGION_GEOMETRY.SHAPE_POLYGON:
			var moved := []
			for point: Vector2 in _region_polygon(region):
				moved.append([point.x + delta.x, point.y + delta.y])
			region["polygon"] = moved
		elif REGION_GEOMETRY.canonical_shape(region) == REGION_GEOMETRY.SHAPE_BOX:
			var box: Array = region.get("box", [])
			if box.size() == 4:
				box[0] = float(box[0]) + delta.x
				box[1] = float(box[1]) + delta.y
		return


func _resized_box(box: Variant, handle: int, point: Vector2) -> Array:
	if not box is Array or box.size() != 4:
		return []
	var left := float(box[0])
	var top := float(box[1])
	var right := left + float(box[2])
	var bottom := top + float(box[3])
	if handle in [0, 6, 7]:
		left = minf(point.x, right - 1.0)
	if handle in [0, 1, 2]:
		top = minf(point.y, bottom - 1.0)
	if handle in [2, 3, 4]:
		right = maxf(point.x, left + 1.0)
	if handle in [4, 5, 6]:
		bottom = maxf(point.y, top + 1.0)
	return [left, top, right - left, bottom - top]


func _resize_polygon_preview(
	points: PackedVector2Array,
	handle: int,
	target: Vector2,
) -> PackedVector2Array:
	if points.size() < 3 or handle < 0 or handle > 7:
		return PackedVector2Array()
	var old_bounds: Rect2 = POLYGON_OPS.polygon_bounds(points)
	if old_bounds.size.x <= 0.0 or old_bounds.size.y <= 0.0:
		return PackedVector2Array()
	var minimum := old_bounds.position
	var maximum := old_bounds.end
	if handle in [0, 6, 7]:
		minimum.x = minf(target.x, old_bounds.end.x - 1.0)
	elif handle in [2, 3, 4]:
		maximum.x = maxf(target.x, old_bounds.position.x + 1.0)
	if handle in [0, 1, 2]:
		minimum.y = minf(target.y, old_bounds.end.y - 1.0)
	elif handle in [4, 5, 6]:
		maximum.y = maxf(target.y, old_bounds.position.y + 1.0)
	var scale := (maximum - minimum) / old_bounds.size
	var resized := PackedVector2Array()
	for point: Vector2 in points:
		resized.append(minimum + (point - old_bounds.position) * scale)
	return resized


func _normalized_box(start: Vector2, finish: Vector2) -> Array:
	var left := minf(start.x, finish.x)
	var top := minf(start.y, finish.y)
	return [left, top, absf(finish.x - start.x), absf(finish.y - start.y)]


func _box_path(box: Array) -> PackedVector2Array:
	if box.size() != 4:
		return PackedVector2Array()
	var position := Vector2(float(box[0]), float(box[1]))
	var end := position + Vector2(float(box[2]), float(box[3]))
	return PackedVector2Array([
		position,
		Vector2(end.x, position.y),
		end,
		Vector2(position.x, end.y),
		position,
	])


func _closed_path(points: PackedVector2Array) -> PackedVector2Array:
	var result := points.duplicate()
	if result.size() >= 2 and not result[-1].is_equal_approx(result[0]):
		result.append(result[0])
	return result


func _stroke_close_distance(points: PackedVector2Array, require_proximity: bool) -> float:
	if not require_proximity:
		return 0.0
	if points.size() < 2:
		return -1.0
	var image_distance := points[0].distance_to(points[-1])
	var transform: Variant = _viewport.get_image_transform() if _is_live_object(_viewport) and _viewport.has_method("get_image_transform") else null
	if transform is Object and transform.has_method("image_to_viewport"):
		var first_view: Variant = transform.image_to_viewport(points[0])
		var last_view: Variant = transform.image_to_viewport(points[-1])
		if first_view is Vector2 and last_view is Vector2:
			return image_distance + 0.001 if first_view.distance_to(last_view) <= FREEHAND_CLOSE_VIEWPORT_PX else -1.0
	return image_distance + 0.001 if image_distance <= FREEHAND_CLOSE_DISTANCE else -1.0


func _solid_gesture_candidate(points: PackedVector2Array, image_size: Vector2) -> Dictionary:
	var raster_size := Vector2i(roundi(image_size.x), roundi(image_size.y))
	var boundary := MASK_REGION_OPS.rasterize_stroke_mask(
		_closed_path(points),
		GESTURE_BOUNDARY_RADIUS,
		raster_size,
	)
	if not bool(boundary.get("ok", false)):
		return boundary
	return MASK_REGION_OPS.fill_all_enclosed(boundary, raster_size)


func _append_stroke_point(point: Vector2) -> void:
	if _stroke_points.size() >= MAX_GESTURE_POINTS:
		return
	if _stroke_points.is_empty() or _stroke_points[-1].distance_to(point) >= FREEHAND_SAMPLE_DISTANCE:
		_stroke_points.append(point)


func _bounded_preview_points(points: PackedVector2Array) -> PackedVector2Array:
	if points.size() <= MAX_PREVIEW_POINTS:
		return points.duplicate()
	var sampled := PackedVector2Array()
	for sample_index in range(MAX_PREVIEW_POINTS):
		var source_index := int(floor(
			float(sample_index) * float(points.size() - 1) / float(MAX_PREVIEW_POINTS - 1)
		))
		sampled.append(points[source_index])
	return sampled


func _finish_lasso_candidate(points: PackedVector2Array, require_proximity: bool) -> bool:
	return _finalize_lasso(
		_drag_frame,
		_drag_before.duplicate(true),
		points,
		_drag_image_size,
		require_proximity,
		_lasso_mode in [&"anchors", &"anchor_press", &"invalid"],
	)


func _commit_pointer_subtract_with_space() -> bool:
	var points := _stroke_points.duplicate()
	if points.is_empty():
		var snapshot: Variant = _session.points
		if snapshot is PackedVector2Array:
			points = snapshot.duplicate()
	return _commit_region_stroke(
		&"subtract",
		_drag_frame if _drag_frame >= 0 else _session.frame,
		_drag_before.duplicate(true) if not _drag_before.is_empty() else _session.before.duplicate(true),
		_drag_region_id if not _drag_region_id.is_empty() else _session.region_id,
		points,
		_drag_image_size if _drag_image_size != Vector2.ZERO else _current_image_size(),
		false,
	)


func _finalize_lasso(
	frame: int,
	before: Dictionary,
	stroke: PackedVector2Array,
	image_size: Vector2,
	require_proximity: bool,
	preserve_vertices := false,
) -> bool:
	var retained_candidate := _editable_lasso_candidate(stroke)
	if not POLYGON_OPS.points_fit_image(stroke, image_size):
		_retain_invalid_lasso(
			frame,
			before,
			stroke,
			retained_candidate,
			"Lasso refused: every point must stay inside the current image",
		)
		return false
	var close_distance := _stroke_close_distance(stroke, require_proximity)
	var ring := PackedVector2Array()
	if preserve_vertices:
		# 点击轮廓使用原始控制点，不做简化或像素轮廓重建。
		var exact := stroke.duplicate()
		if exact.size() > 1 and exact[0].is_equal_approx(exact[-1]):
			exact.remove_at(exact.size() - 1)
		if POLYGON_OPS.validate_simple_polygon(exact):
			ring = exact
	elif close_distance >= 0.0:
		ring = POLYGON_OPS.sanitize_freehand(
			stroke,
			FREEHAND_SIMPLIFY_TOLERANCE,
			close_distance,
		)
	if ring.is_empty() and close_distance >= 0.0 and not preserve_vertices:
		var solid := _solid_gesture_candidate(stroke, image_size)
		if StringName(solid.get("status", &"")) == MASK_REGION_OPS.STATUS_SINGLE:
			_await_class_for_polygon(frame, before, solid.get("polygon", PackedVector2Array()), image_size, &"lasso")
			return true
	if ring.is_empty():
		_retain_invalid_lasso(
			frame,
			before,
			stroke,
			retained_candidate,
			"Lasso refused: draw one finite, non-self-intersecting contour with at least three vertices",
		)
		return false
	_await_class_for_polygon(frame, before, ring, image_size, &"lasso")
	return true


func _retain_invalid_lasso(
	frame: int,
	before: Dictionary,
	raw_path: PackedVector2Array,
	candidate: PackedVector2Array,
	message: String,
) -> void:
	var keyboard_owned := _keyboard_tool == &"lasso"
	_session.begin(&"lasso", frame, "", before)
	_session.set_invalid(
		_bounded_preview_points(raw_path),
		message,
		{},
		EDIT_SESSION.INVALID_COLOR,
		candidate,
	)
	if not keyboard_owned:
		_lasso_anchors = candidate.duplicate()
		_lasso_mode = &"invalid"
		_lasso_invalid_message = message
		_drag_kind = ""
	_push_session_overlay()
	_report(message)
	_refresh_visible_frame(frame)


func _editable_lasso_candidate(points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point: Vector2 in points:
		if result.is_empty() or not result[-1].is_equal_approx(point):
			result.append(point)
	if result.size() > 1 and result[0].is_equal_approx(result[-1]):
		result.remove_at(result.size() - 1)
	return result


func _commit_region_stroke(
	kind: StringName,
	frame: int,
	before: Dictionary,
	region_id: String,
	stroke: PackedVector2Array,
	image_size: Vector2,
	require_proximity := true,
) -> bool:
	if not POLYGON_OPS.points_fit_image(stroke, image_size):
		_retain_invalid_subtract(
			frame,
			before,
			region_id,
			stroke,
			{},
			"Subtract refused: every point must stay inside the current image",
		)
		return false
	var close_distance := _stroke_close_distance(stroke, require_proximity)
	var tool_polygon := PackedVector2Array()
	var tool_mask: Dictionary = {}
	if close_distance >= 0.0:
		tool_polygon = POLYGON_OPS.sanitize_freehand(
			stroke,
			FREEHAND_SIMPLIFY_TOLERANCE,
			close_distance,
		)
	if tool_polygon.is_empty() and close_distance >= 0.0:
		tool_mask = _solid_gesture_candidate(stroke, image_size)
	if tool_polygon.is_empty():
		if StringName(tool_mask.get("status", &"")) == MASK_REGION_OPS.STATUS_SINGLE:
			if region_id.is_empty():
				return _commit_unselected_subtract(frame, before, stroke, tool_polygon, image_size, tool_mask)
			var masked_region := _find_region(before, region_id)
			var masked_subject := _region_polygon(masked_region)
			if not masked_subject.is_empty():
				var masked_result := _subtract_geometry(masked_subject, tool_polygon, tool_mask, image_size)
				return _commit_boolean_result(frame, before, region_id, masked_subject, stroke, masked_result, image_size)
		_retain_invalid_subtract(
			frame,
			before,
			region_id,
			stroke,
			{},
			"Subtract refused: draw one finite, simple closed contour",
		)
		return false
	if region_id.is_empty():
		return _commit_unselected_subtract(frame, before, stroke, tool_polygon, image_size, tool_mask)
	var region := _find_region(before, region_id)
	var subject := _region_polygon(region)
	if subject.is_empty():
		_retain_invalid_subtract(
			frame,
			before,
			region_id,
			stroke,
			{},
			"%s refused: selected region has no V1-safe geometry" % kind,
		)
		return false
	var result: Dictionary = _subtract_geometry(subject, tool_polygon, tool_mask, image_size)
	return _commit_boolean_result(frame, before, region_id, subject, stroke, result, image_size)


func _commit_unselected_subtract(
	frame: int,
	before: Dictionary,
	stroke: PackedVector2Array,
	tool_polygon: PackedVector2Array,
	image_size: Vector2,
	tool_mask: Dictionary = {},
) -> bool:
	var regions_value: Variant = before.get("regions", [])
	if not regions_value is Array:
		_retain_invalid_subtract(frame, before, "", stroke, {}, "Subtract refused: current frame regions are invalid")
		return false
	var next_regions: Array = []
	var changed_count := 0
	var deleted_count := 0
	for value: Variant in regions_value:
		if not value is Dictionary:
			_retain_invalid_subtract(frame, before, "", stroke, {}, "Subtract refused: current frame contains an invalid region")
			return false
		var region: Dictionary = value.duplicate(true)
		var subject := _region_polygon(region)
		if subject.is_empty():
			_retain_invalid_subtract(frame, before, "", stroke, {}, "Subtract refused: a region has no V1-safe geometry")
			return false
		var result: Dictionary = _subtract_geometry(subject, tool_polygon, tool_mask, image_size)
		match StringName(result.get("status", &"")):
			POLYGON_OPS.STATUS_SINGLE:
				var polygon: PackedVector2Array = result.get("polygon", PackedVector2Array())
				if POLYGON_OPS.equivalent_ring(polygon, subject):
					next_regions.append(region)
					continue
				if not POLYGON_OPS.validate_simple_polygon(polygon) or not POLYGON_OPS.points_fit_image(polygon, image_size):
					_retain_invalid_subtract(frame, before, "", stroke, result, "Subtract refused atomically: one remainder is not a bounded simple Model Output V1 polygon")
					return false
				region.erase("box")
				region["polygon"] = _polygon_to_array(polygon)
				next_regions.append(region)
				changed_count += 1
			POLYGON_OPS.STATUS_EMPTY:
				changed_count += 1
				deleted_count += 1
			_:
				var detail := str(result.get("message", "Model Output V1 cannot store this topology"))
				_retain_invalid_subtract(frame, before, "", stroke, result, "Subtract refused atomically: %s" % detail)
				return false
	if changed_count == 0:
		_retain_invalid_subtract(frame, before, "", stroke, {}, "Subtract found no overlapping regions")
		return false
	var after := before.duplicate(true)
	after["regions"] = next_regions
	var errors: PackedStringArray = _history.execute(REPLACE_FRAME_COMMAND.new(frame, before, after), _store)
	if not errors.is_empty():
		_retain_invalid_subtract(frame, before, "", stroke, {}, "; ".join(errors))
		return false
	_clear_transient()
	_refresh_visible_frame(frame)
	_validate_current_selection()
	_report("Subtract updated %d region(s), including %d complete deletion(s)" % [changed_count, deleted_count])
	return true


func _subtract_geometry(
	subject: PackedVector2Array,
	tool_polygon: PackedVector2Array,
	tool_mask: Dictionary,
	image_size: Vector2,
) -> Dictionary:
	if not tool_polygon.is_empty():
		return POLYGON_OPS.difference(subject, tool_polygon)
	var raster_size := Vector2i(roundi(image_size.x), roundi(image_size.y))
	var subject_mask := MASK_REGION_OPS.rasterize_polygon(subject, raster_size)
	if not bool(subject_mask.get("ok", false)):
		return subject_mask
	return MASK_REGION_OPS.combine(subject_mask, tool_mask, &"subtract")


func _commit_brush_stroke(
	tool_id: StringName,
	frame: int,
	before: Dictionary,
	region_id: String,
	stroke: PackedVector2Array,
	image_size: Vector2,
) -> void:
	var raster_size := Vector2i(roundi(image_size.x), roundi(image_size.y))
	var stroke_result := _buffered_stroke(stroke)
	if not bool(stroke_result.get("ok", false)):
		_show_brush_refusal(tool_id, frame, before, region_id, stroke, stroke_result, "%s refused: %s" % [_brush_label(tool_id), stroke_result.get("message", "invalid stroke")])
		return
	if tool_id == &"paint":
		if _brush_region_masks.is_empty():
			_cache_brush_regions(before, raster_size)
		var operation := _paint_operation(stroke_result, region_id)
		if not bool(operation.get("ok", false)):
			_show_brush_refusal(tool_id, frame, before, region_id, stroke, stroke_result, str(operation.get("message", "Paint refused")))
			return
		var target_id := str(operation.get("target_id", ""))
		var raw_result: Dictionary = operation.get("result", {})
		var candidate := MASK_REGION_OPS.to_v1_candidate(raw_result)
		if target_id.is_empty():
			var candidate_status := StringName(candidate.get("status", &""))
			if candidate_status == MASK_REGION_OPS.STATUS_HOLE:
				var message := "Paint outline is ready for Fill; click inside the smallest closed area, or press Escape"
				_session.begin(&"paint", frame, "", before)
				_session.set_working_mask(raw_result, message)
				_clear_pointer_drag_state()
				_push_session_overlay()
				_report(message)
				_refresh_visible_frame(frame)
				return
			if candidate_status != MASK_REGION_OPS.STATUS_SINGLE:
				_show_brush_refusal(tool_id, frame, before, "", stroke, candidate, "Paint refused: %s" % candidate.get("message", "new object is not one simple V1 region"))
				return
			_await_class_for_polygon(frame, before, candidate.get("polygon", PackedVector2Array()), image_size, &"paint")
			return
		_commit_selected_brush_result(
			tool_id,
			frame,
			before,
			target_id,
			operation.get("subject", PackedVector2Array()),
			stroke,
			candidate,
			image_size,
		)
		return
	# 先验证整批候选，再提交一个命令，避免只擦除部分对象。
	var operation := _eraser_operation(stroke_result)
	if not bool(operation.get("ok", false)):
		_show_brush_refusal(tool_id, frame, before, "", stroke, stroke_result, "Eraser refused: %s" % operation.message)
		return
	var after := before.duplicate(true)
	for entry: Dictionary in operation.regions:
		var candidate := MASK_REGION_OPS.to_v1_candidate(entry.mask)
		var status := StringName(candidate.get("status", &""))
		if status == MASK_REGION_OPS.STATUS_EMPTY:
			for index in range(after.regions.size() - 1, -1, -1):
				if after.regions[index].id == entry.id:
					after.regions.remove_at(index)
		elif status == MASK_REGION_OPS.STATUS_SINGLE:
			var replacement = REPLACE_GEOMETRY_COMMAND.new(frame, after, entry.id, candidate.polygon, image_size)
			if not replacement._construction_errors.is_empty():
				_show_brush_refusal(tool_id, frame, before, "", stroke, stroke_result, "Eraser refused: %s" % replacement._construction_errors[0])
				return
			after = replacement.after
		else:
			_show_brush_refusal(tool_id, frame, before, "", stroke, stroke_result, "Eraser refused for region %s: %s" % [entry.id, candidate.get("message", "Invalid geometry")])
			return
	if _store.get_corrected_record(frame) != before:
		_show_brush_refusal(tool_id, frame, before, "", stroke, stroke_result, "Eraser refused: frame changed during the stroke; start a new stroke")
		return
	_clear_transient()
	if after == before:
		_report("Eraser did not touch any region")
		_refresh_visible_frame(frame)
		return
	if _execute(REPLACE_FRAME_COMMAND.new(frame, before, after), frame).is_empty():
		_validate_current_selection()


func _commit_selected_brush_result(
	tool_id: StringName,
	frame: int,
	before: Dictionary,
	region_id: String,
	subject: PackedVector2Array,
	stroke: PackedVector2Array,
	result: Dictionary,
	image_size: Vector2,
) -> void:
	if StringName(result.get("status", &"")) != MASK_REGION_OPS.STATUS_SINGLE:
		_show_brush_refusal(
			tool_id,
			frame,
			before,
			region_id,
			stroke,
			result,
			"%s refused: %s" % [_brush_label(tool_id), result.get("message", "result is not one simple V1 region")],
		)
		return
	var polygon: PackedVector2Array = result.get("polygon", PackedVector2Array())
	if POLYGON_OPS.equivalent_ring(polygon, subject):
		_clear_transient()
		_report("Geometry is unchanged")
		_refresh_visible_frame(frame)
		return
	_clear_transient()
	var errors := _execute(REPLACE_GEOMETRY_COMMAND.new(frame, before, region_id, polygon, image_size), frame)
	if errors.is_empty():
		if _current_frame() == frame:
			_set_selected_region(region_id)
		else:
			_validate_current_selection()


func _show_brush_refusal(
	tool_id: StringName,
	frame: int,
	before: Dictionary,
	region_id: String,
	stroke: PackedVector2Array,
	result: Dictionary,
	message: String,
) -> void:
	_session.begin(tool_id, frame, region_id, before)
	_session.set_brush_preview(
		result,
		stroke[-1] if not stroke.is_empty() else Vector2.ZERO,
		0.0,
		_brush_overlay_color(tool_id),
		message,
		true,
	)
	_push_session_overlay()
	_report(message)
	_refresh_visible_frame(frame)


func _brush_label(tool_id: StringName) -> String:
	return "Eraser" if tool_id == &"eraser" else "Paint"


func _brush_overlay_color(tool_id: StringName) -> Color:
	return ERASER_OVERLAY_COLOR if tool_id == &"eraser" else PAINT_OVERLAY_COLOR


func _commit_boolean_result(
	frame: int,
	before: Dictionary,
	region_id: String,
	subject: PackedVector2Array,
	stroke: PackedVector2Array,
	result: Dictionary,
	image_size: Vector2,
) -> bool:
	var message := ""
	match StringName(result.get("status", "")):
		POLYGON_OPS.STATUS_SINGLE:
			var polygon: PackedVector2Array = result.get("polygon", PackedVector2Array())
			if POLYGON_OPS.equivalent_ring(polygon, subject):
				message = "Geometry is unchanged"
			elif not POLYGON_OPS.validate_simple_polygon(polygon) or not POLYGON_OPS.points_fit_image(polygon, image_size):
				message = "Subtract refused: result is not one bounded simple Model Output V1 polygon"
			else:
				var command = REPLACE_GEOMETRY_COMMAND.new(frame, before, region_id, polygon, image_size)
				var errors: PackedStringArray = _history.execute(command, _store)
				if errors.is_empty():
					_clear_transient()
					_refresh_visible_frame(frame)
					if _current_frame() == frame:
						_set_selected_region(region_id)
					else:
						_validate_current_selection()
					return true
				message = "; ".join(errors)
		POLYGON_OPS.STATUS_EMPTY:
			message = "Subtract refused: removing the whole region requires Delete or Backspace in Selection"
		_:
			message = str(result.get("message", "Model Output V1 cannot store this topology"))
	_retain_invalid_subtract(frame, before, region_id, stroke, result, message)
	return false


func _retain_invalid_subtract(
	frame: int,
	before: Dictionary,
	region_id: String,
	stroke: PackedVector2Array,
	result: Dictionary,
	message: String,
) -> void:
	_session.begin(&"subtract", frame, region_id, before)
	_session.set_invalid(
		_bounded_preview_points(stroke),
		message,
		result,
		EDIT_SESSION.INVALID_COLOR,
		_editable_lasso_candidate(stroke),
	)
	if _keyboard_tool != &"subtract":
		_drag_kind = ""
	_push_session_overlay()
	_report(message)
	_refresh_visible_frame(frame)


func _current_image_size() -> Vector2:
	if not _is_live_object(_viewport) or not _viewport.has_method("get_image_transform"):
		return Vector2.ZERO
	var transform: Variant = _viewport.get_image_transform()
	if not transform is Object or not transform.has_method("is_configured") or not transform.is_configured():
		return Vector2.ZERO
	var image_size_value: Variant = transform.image_size
	if not image_size_value is Vector2:
		return Vector2.ZERO
	var image_size: Vector2 = image_size_value
	if not image_size.is_finite() or image_size.x <= 0.0 or image_size.y <= 0.0:
		return Vector2.ZERO
	return image_size


func _region_polygon(region: Dictionary) -> PackedVector2Array:
	if REGION_GEOMETRY.canonical_shape(region) == REGION_GEOMETRY.SHAPE_POLYGON:
		var result := PackedVector2Array()
		for value: Variant in region.get("polygon", []):
			if value is Array and value.size() == 2:
				result.append(Vector2(float(value[0]), float(value[1])))
		return result
	if REGION_GEOMETRY.canonical_shape(region) == REGION_GEOMETRY.SHAPE_BOX:
		return POLYGON_OPS.box_to_polygon(region.get("box", []))
	return PackedVector2Array()


func _polygon_to_array(points: PackedVector2Array) -> Array:
	var result: Array = []
	for point: Vector2 in points:
		result.append([point.x, point.y])
	return result


func _polygon_from_array(value: Variant) -> PackedVector2Array:
	var result := PackedVector2Array()
	if not value is Array:
		return result
	for item: Variant in value:
		if not item is Array or item.size() != 2:
			return PackedVector2Array()
		if typeof(item[0]) not in [TYPE_INT, TYPE_FLOAT] or typeof(item[1]) not in [TYPE_INT, TYPE_FLOAT]:
			return PackedVector2Array()
		var point := Vector2(float(item[0]), float(item[1]))
		if not point.is_finite():
			return PackedVector2Array()
		result.append(point)
	return result


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


func _set_drawing_overlay(
	path: PackedVector2Array,
	next_cursor: Vector2,
	radius: float,
	fill_color: Color = EDIT_SESSION.DRAWING_COLOR,
) -> void:
	_session.set_drawing(path, next_cursor, radius, fill_color)
	_push_session_overlay()


func _show_idle_brush_cursor() -> void:
	if (
		not _active
		or _active_tool not in [&"paint", &"eraser"]
		or _session.phase not in [EDIT_SESSION.IDLE, EDIT_SESSION.BRUSH_CURSOR]
	):
		return
	var image_size := _current_image_size()
	if image_size == Vector2.ZERO:
		return
	var cursor := _last_pointer_image_position if _has_last_pointer_image_position else image_size * 0.5
	cursor.x = clampf(cursor.x, 0.0, image_size.x)
	cursor.y = clampf(cursor.y, 0.0, image_size.y)
	_session.set_brush_cursor(
		_active_tool,
		cursor,
		_brush_radius_image_px,
		_brush_overlay_color(_active_tool),
	)
	_push_session_overlay()


func _set_geometry_preview_overlay(
	path: PackedVector2Array,
	next_cursor: Vector2,
	radius: float,
	image_size: Vector2,
) -> void:
	if POLYGON_OPS.points_fit_image(path, image_size):
		_set_drawing_overlay(path, next_cursor, radius)
		return
	_session.set_invalid(path, "Geometry must stay inside the current image")
	_push_session_overlay()


func _push_session_overlay() -> void:
	if _is_live_object(_viewport) and _viewport.has_method("set_edit_overlay"):
		var overlay: Dictionary = _session.overlay_snapshot()
		if _active_tool == &"lasso" and not _session.has_pending_class_assignment() and _lasso_mode in [&"anchors", &"anchor_press", &"vertex_drag", &"invalid"]:
			overlay["vertex_points"] = _lasso_anchors.duplicate()
			overlay["active_vertex"] = _lasso_active_anchor
		_viewport.set_edit_overlay(overlay)
	_emit_edit_state()


func _clear_transient() -> void:
	var state_changed: bool = _session.phase != EDIT_SESSION.IDLE or _vertex_editor.dragging
	_vertex_editor.clear()
	_vertex_mode_requested = false
	_add_pointer_mode = false
	_clear_pointer_drag_state()
	_keyboard_box = []
	_lasso_mode = &""
	_lasso_anchors = PackedVector2Array()
	_lasso_press_position = Vector2.ZERO
	_lasso_release_suppressed = false
	_lasso_invalid_message = ""
	_lasso_active_anchor = -1
	_lasso_vertex_moved = false
	_keyboard_tool = &""
	_keyboard_cursor = Vector2.ZERO
	_keyboard_points = PackedVector2Array()
	_keyboard_frame = -1
	_keyboard_region_id = ""
	_keyboard_before = {}
	_session.reset()
	if _is_live_object(_viewport) and _viewport.has_method("clear_edit_overlay"):
		_viewport.clear_edit_overlay()
	if state_changed:
		_emit_edit_state()


func _clear_pointer_drag_state() -> void:
	_drag_kind = ""
	_drag_frame = -1
	_drag_region_id = ""
	_drag_start = Vector2.ZERO
	_drag_before = {}
	_drag_image_size = Vector2.ZERO
	_resize_handle = -1
	_keyboard_box = []
	_stroke_points = PackedVector2Array()
	_brush_region_masks.clear()
	_brush_buffer.reset()
	_buffered_points = 0
	_brush_error = ""


func _is_pointer_drag() -> bool:
	return _drag_kind in ["move", "resize", "add", "lasso", "subtract", "paint", "eraser"]


func _has_transient_edit() -> bool:
	return (
		_vertex_editor.dragging
		or _session.phase not in [EDIT_SESSION.IDLE, EDIT_SESSION.BRUSH_CURSOR]
		or not _drag_kind.is_empty()
		or not _lasso_mode.is_empty()
		or not _keyboard_tool.is_empty()
	)


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


func _emit_edit_state() -> void:
	if _edit_state_callback.is_valid():
		_edit_state_callback.call(get_edit_state())


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
