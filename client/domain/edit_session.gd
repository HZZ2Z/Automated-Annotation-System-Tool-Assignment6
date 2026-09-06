class_name EditSession
extends RefCounted

const IDLE := &"idle"
const BRUSH_CURSOR := &"brush_cursor"
const DRAWING := &"drawing"
const WORKING_MASK := &"working_mask"
const CANDIDATE := &"candidate"
const AWAITING_CLASS := &"awaiting_class"
const INVALID := &"invalid"
const DRAFT_HISTORY := preload("res://client/domain/mask_draft_history.gd")

const DRAWING_COLOR := Color("#22d3ee")
const CANDIDATE_COLOR := Color("#22c55e")
const WORKING_MASK_COLOR := Color("#f97316")
const INVALID_COLOR := Color("#ef4444")

var phase: StringName = IDLE
var tool_id: StringName = &""
var frame := -1
var region_id := ""
var before: Dictionary = {}
var points := PackedVector2Array()
var working_mask: Dictionary = {}
var candidate_polygon := PackedVector2Array()
var cursor := Vector2.ZERO
var brush_radius := 0.0
var message := ""
var fill_color := Color.TRANSPARENT
var _pending_geometry: Dictionary = {}
var _pending_image_size := Vector2.ZERO
var _pending_token := -1
var _draft_history = DRAFT_HISTORY.new()
var _fill_repair: Dictionary = {}
var _repair_previous: Dictionary = {}
var _brush_previews: Array[Dictionary] = []


func begin(next_tool_id: StringName, next_frame: int, next_region_id: String, store_record: Dictionary) -> void:
	reset()
	tool_id = next_tool_id
	frame = next_frame
	region_id = next_region_id
	before = store_record.duplicate(true)


func set_drawing(path: PackedVector2Array, next_cursor: Vector2, next_brush_radius: float, next_fill_color: Color = DRAWING_COLOR) -> void:
	phase = DRAWING
	points = path.duplicate()
	working_mask = {}
	candidate_polygon = PackedVector2Array()
	cursor = next_cursor
	brush_radius = next_brush_radius
	message = ""
	fill_color = next_fill_color


func set_brush_cursor(
	next_tool_id: StringName,
	next_cursor: Vector2,
	next_brush_radius: float,
	next_fill_color: Color,
) -> void:
	reset()
	phase = BRUSH_CURSOR
	tool_id = next_tool_id
	cursor = next_cursor
	brush_radius = next_brush_radius
	fill_color = next_fill_color


func set_candidate(
	polygon: PackedVector2Array,
	next_message: String = "",
	next_fill_color: Color = CANDIDATE_COLOR,
	next_path: PackedVector2Array = PackedVector2Array(),
	next_cursor: Vector2 = Vector2.ZERO,
) -> void:
	phase = CANDIDATE
	points = next_path.duplicate()
	working_mask = {}
	candidate_polygon = polygon.duplicate()
	cursor = next_cursor
	brush_radius = 0.0
	message = next_message
	fill_color = next_fill_color


func set_brush_preview(
	mask_snapshot: Dictionary,
	next_cursor: Vector2,
	next_brush_radius: float,
	next_fill_color: Color,
	next_message: String = "",
	invalid := false,
) -> void:
	_brush_previews.clear()
	phase = INVALID if invalid else DRAWING
	points = PackedVector2Array()
	working_mask = _duplicate_mask_snapshot(mask_snapshot)
	candidate_polygon = PackedVector2Array()
	cursor = next_cursor
	brush_radius = next_brush_radius
	message = next_message
	fill_color = INVALID_COLOR if invalid else next_fill_color


func set_batch_brush_preview(regions: Array) -> void:
	_brush_previews = []
	for entry: Dictionary in regions:
		_brush_previews.append({"id": str(entry.id), "mask": _duplicate_mask_snapshot(entry.mask)})
	working_mask = _brush_previews[0].mask.duplicate(true) if not _brush_previews.is_empty() else {}


func set_working_mask(mask_snapshot: Dictionary, next_message: String = "", next_fill_color: Color = WORKING_MASK_COLOR) -> void:
	var next_mask := _duplicate_mask_snapshot(mask_snapshot)
	if has_working_mask() and not next_mask.is_empty():
		_draft_history.record(working_mask, next_mask)
	phase = WORKING_MASK
	points = PackedVector2Array()
	working_mask = next_mask
	candidate_polygon = PackedVector2Array()
	brush_radius = 0.0
	message = next_message
	fill_color = next_fill_color


func set_awaiting_class(
	geometry: Dictionary,
	image_size: Vector2,
	token: int,
	next_message: String = "",
) -> void:
	phase = AWAITING_CLASS
	points = PackedVector2Array()
	working_mask = {}
	_pending_geometry = geometry.duplicate(true)
	_pending_image_size = image_size
	_pending_token = token
	candidate_polygon = _pending_candidate_polygon(_pending_geometry)
	cursor = candidate_polygon[-1] if not candidate_polygon.is_empty() else Vector2.ZERO
	brush_radius = 0.0
	message = next_message
	fill_color = CANDIDATE_COLOR


func set_invalid(
	path: PackedVector2Array,
	next_message: String = "",
	mask_snapshot: Dictionary = {},
	next_fill_color: Color = INVALID_COLOR,
	next_candidate_polygon: PackedVector2Array = PackedVector2Array(),
) -> void:
	phase = INVALID
	points = path.duplicate()
	working_mask = _duplicate_mask_snapshot(mask_snapshot)
	candidate_polygon = next_candidate_polygon.duplicate()
	cursor = path[-1] if not path.is_empty() else Vector2.ZERO
	brush_radius = 0.0
	message = next_message
	fill_color = next_fill_color


func reset() -> void:
	_brush_previews.clear()
	phase = IDLE
	tool_id = &""
	frame = -1
	region_id = ""
	before = {}
	points = PackedVector2Array()
	working_mask = {}
	candidate_polygon = PackedVector2Array()
	cursor = Vector2.ZERO
	brush_radius = 0.0
	message = ""
	fill_color = Color.TRANSPARENT
	_pending_geometry = {}
	_pending_image_size = Vector2.ZERO
	_pending_token = -1
	_draft_history.clear()
	_fill_repair = {}
	_repair_previous = {}


func set_working_cursor(point: Vector2) -> void:
	cursor = point
	points = PackedVector2Array([point])


func set_fill_repair(result: Dictionary, seed: Vector2) -> void:
	_repair_previous = {"phase": phase, "mask": working_mask.duplicate(true),
		"points": points.duplicate(), "cursor": cursor, "message": message, "color": fill_color}
	_fill_repair = result.duplicate(true)
	phase = CANDIDATE
	working_mask = _duplicate_mask_snapshot(result)
	candidate_polygon = PackedVector2Array()
	set_working_cursor(seed)
	fill_color = CANDIDATE_COLOR
	message = str(result.message)


func has_fill_repair() -> bool:
	return not _fill_repair.is_empty()


func cancel_fill_repair() -> void:
	if not has_fill_repair():
		return
	phase = _repair_previous.phase
	working_mask = _repair_previous.mask.duplicate(true)
	points = _repair_previous.points.duplicate()
	cursor = _repair_previous.cursor
	message = _repair_previous.message
	fill_color = _repair_previous.color
	_fill_repair = {}
	_repair_previous = {}


func take_fill_repair() -> Dictionary:
	var result := _fill_repair.duplicate(true)
	cancel_fill_repair()
	return result


func draft_counts() -> Dictionary:
	return _draft_history.counts()


func change_draft_history(redo: bool) -> PackedStringArray:
	if has_fill_repair():
		cancel_fill_repair()
		return PackedStringArray()
	if not has_working_mask():
		return PackedStringArray(["No Fill contour is active"])
	var restored: Dictionary = _draft_history.redo(working_mask) if redo else _draft_history.undo(working_mask)
	if restored.is_empty():
		return PackedStringArray(["Contour: nothing to redo" if redo else "Contour: nothing to undo"])
	working_mask = restored
	message = "Contour fill redone" if redo else "Contour fill undone"
	return PackedStringArray()


func has_working_mask() -> bool:
	return phase == WORKING_MASK and not working_mask.is_empty()


func has_pending_class_assignment() -> bool:
	return phase == AWAITING_CLASS and not _pending_geometry.is_empty() and _pending_token >= 0


func pending_request() -> Dictionary:
	if not has_pending_class_assignment():
		return {}
	return {
		"candidate_token": _pending_token,
		"frame": frame,
		"tool_id": tool_id,
	}


func _pending_commit_snapshot() -> Dictionary:
	if not has_pending_class_assignment():
		return {}
	return {
		"geometry": _pending_geometry.duplicate(true),
		"image_size": _pending_image_size,
		"candidate_token": _pending_token,
	}


func overlay_snapshot() -> Dictionary:
	if phase == IDLE:
		return {}
	var snapshot := {
		"phase": phase,
		"path": points.duplicate(),
		"candidate_polygon": candidate_polygon.duplicate(),
		"mask_preview": _duplicate_mask_snapshot(working_mask),
		"cursor": cursor,
		"brush_radius": brush_radius,
		"message": message,
		"fill_color": fill_color,
	}
	if tool_id in [&"paint", &"eraser"] and not region_id.is_empty() and not working_mask.is_empty():
		snapshot["suppress_region_id"] = region_id
	if not _brush_previews.is_empty():
		var ids := PackedStringArray()
		var masks: Array[Dictionary] = []
		for entry: Dictionary in _brush_previews:
			ids.append(entry.id)
			masks.append(entry.mask.duplicate(true))
		if ids.size() == 1:
			snapshot["suppress_region_id"] = ids[0]
		else:
			snapshot["suppress_region_ids"] = ids
		snapshot["mask_previews"] = masks
	if has_fill_repair():
		snapshot["repair_mask"] = _fill_repair.repair_mask.duplicate(true)
	return snapshot


func _duplicate_mask_snapshot(value: Dictionary) -> Dictionary:
	if value.is_empty():
		return {}
	var roi: Variant = value.get("roi")
	var mask: Variant = value.get("mask")
	if not roi is Rect2i or not mask is PackedByteArray:
		return {}
	if roi.size.x <= 0 or roi.size.y <= 0 or roi.size.x * roi.size.y != mask.size():
		return {}
	return {"roi": roi, "mask": mask.duplicate()}


func _pending_candidate_polygon(geometry: Dictionary) -> PackedVector2Array:
	var shape := StringName(geometry.get("shape", &""))
	if shape == &"polygon":
		var polygon: Variant = geometry.get("polygon")
		return polygon.duplicate() if polygon is PackedVector2Array else PackedVector2Array()
	if shape != &"box":
		return PackedVector2Array()
	var box: Variant = geometry.get("box")
	if not box is Array or box.size() != 4:
		return PackedVector2Array()
	for value: Variant in box:
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)):
			return PackedVector2Array()
	var x := float(box[0])
	var y := float(box[1])
	var width := float(box[2])
	var height := float(box[3])
	return PackedVector2Array([
		Vector2(x, y),
		Vector2(x + width, y),
		Vector2(x + width, y + height),
		Vector2(x, y + height),
	])
