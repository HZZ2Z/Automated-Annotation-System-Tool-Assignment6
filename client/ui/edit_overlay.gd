class_name EditOverlay
extends Control

const DRAWING_COLOR := Color("#22d3ee")
const CANDIDATE_COLOR := Color("#22c55e")
const WORKING_MASK_COLOR := Color("#f97316")
const INVALID_COLOR := Color("#ef4444")
const LINE_WIDTH := 2.0
const POINT_RADIUS := 3.0
const MASK_ALPHA := 0.45

var _state: Dictionary = {}
var _transform: Variant
var _mask_snapshot: Dictionary = {}
var _mask_texture: ImageTexture
var _mask_texture_builds := 0
var _repair_snapshot: Dictionary = {}
var _repair_texture: ImageTexture
var _batch_layers: Array[Dictionary] = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_state(state: Dictionary, image_transform: Variant) -> void:
	_state = state.duplicate(true)
	_transform = image_transform
	_update_mask_texture(_state.get("mask_preview", {}))
	var masks: Array = _state.get("mask_previews", [])
	var layers: Array[Dictionary] = []
	for index in range(1, masks.size()):
		var snapshot := _valid_mask_snapshot(masks[index])
		var previous: Dictionary = _batch_layers[index - 1] if index - 1 < _batch_layers.size() else {}
		var texture: ImageTexture = previous.get("texture")
		if snapshot != previous.get("snapshot", {}):
			texture = _make_mask_texture(snapshot, texture)
		layers.append({"snapshot": snapshot, "texture": texture})
	_batch_layers = layers
	var repair := _valid_mask_snapshot(_state.get("repair_mask", {}))
	if repair != _repair_snapshot:
		_repair_snapshot = repair
		_repair_texture = _make_mask_texture(repair)
	queue_redraw()


func set_transform(image_transform: Variant) -> void:
	_transform = image_transform
	queue_redraw()


func get_state_snapshot() -> Dictionary:
	return _state.duplicate(true)


func get_mask_texture_build_count() -> int:
	return _mask_texture_builds


func _draw() -> void:
	if _state.is_empty() or not _valid_transform():
		return
	var color := _phase_color()
	_draw_mask_preview(color)
	for layer: Dictionary in _batch_layers:
		if layer.texture != null:
			_draw_mask_texture(layer.texture, layer.snapshot, color, MASK_ALPHA)
	if _repair_texture != null:
		_draw_mask_texture(_repair_texture, _repair_snapshot, Color("#f43f5e"), 0.95)
	_draw_candidate(color)
	_draw_path(color)
	_draw_vertices(color)
	_draw_brush_cursor(color)


func _draw_vertices(color: Color) -> void:
	var points: Variant = _state.get("vertex_points", PackedVector2Array())
	if not points is PackedVector2Array:
		return
	var active := int(_state.get("active_vertex", -1))
	for index in range(points.size()):
		var position: Vector2 = _transform.image_to_viewport(points[index])
		var radius := 6.0 if index == active else 4.0
		draw_circle(position, radius + 1.5, Color("#111827"))
		draw_circle(position, radius, Color("#fbbf24") if index == active else color)


func _draw_mask_preview(color: Color) -> void:
	if _mask_texture == null or _mask_snapshot.is_empty():
		return
	_draw_mask_texture(_mask_texture, _mask_snapshot, color, MASK_ALPHA)


func _draw_mask_texture(texture: ImageTexture, snapshot: Dictionary, color: Color, alpha: float) -> void:
	var roi: Rect2i = snapshot["roi"]
	var top_left: Vector2 = _transform.image_to_viewport(Vector2(roi.position))
	var bottom_right: Vector2 = _transform.image_to_viewport(Vector2(roi.end))
	var tint := color
	tint.a = alpha
	draw_texture_rect(texture, Rect2(top_left, bottom_right - top_left).abs(), false, tint)


func _draw_candidate(color: Color) -> void:
	var candidate: Variant = _state.get("candidate_polygon", PackedVector2Array())
	if not candidate is PackedVector2Array or candidate.size() < 3:
		return
	var viewport_points := _to_viewport_points(candidate)
	var fill := color
	fill.a = 0.25
	draw_colored_polygon(viewport_points, fill)
	var closed := viewport_points.duplicate()
	closed.append(viewport_points[0])
	draw_polyline(closed, color, LINE_WIDTH, true)


func _draw_path(color: Color) -> void:
	var path: Variant = _state.get("path", PackedVector2Array())
	if not path is PackedVector2Array or path.is_empty():
		return
	var viewport_points := _to_viewport_points(path)
	if viewport_points.size() == 1:
		draw_circle(viewport_points[0], POINT_RADIUS, color)
		return
	draw_polyline(viewport_points, color, LINE_WIDTH, true)


func _draw_brush_cursor(color: Color) -> void:
	var radius := float(_state.get("brush_radius", 0.0))
	var cursor: Variant = _state.get("cursor", Vector2.ZERO)
	if radius <= 0.0 or not cursor is Vector2:
		return
	var transform_2d: Transform2D = _transform.get_image_to_viewport_transform()
	var viewport_radius := radius * transform_2d.x.length()
	draw_arc(_transform.image_to_viewport(cursor), viewport_radius, 0.0, TAU, 48, color, LINE_WIDTH, true)


func _to_viewport_points(image_points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point: Vector2 in image_points:
		result.append(_transform.image_to_viewport(point))
	return result


func _phase_color() -> Color:
	var explicit: Variant = _state.get("fill_color", Color.TRANSPARENT)
	if explicit is Color and explicit.a > 0.0:
		return explicit
	match StringName(_state.get("phase", &"")):
		&"candidate":
			return CANDIDATE_COLOR
		&"working_mask":
			return WORKING_MASK_COLOR
		&"invalid":
			return INVALID_COLOR
	return DRAWING_COLOR


func _update_mask_texture(value: Variant) -> void:
	var next_snapshot := _valid_mask_snapshot(value)
	if next_snapshot == _mask_snapshot:
		return
	_mask_snapshot = next_snapshot
	if _mask_snapshot.is_empty():
		_mask_texture = null
		return
	_mask_texture = _make_mask_texture(_mask_snapshot, _mask_texture)
	_mask_texture_builds += 1


func _make_mask_texture(snapshot: Dictionary, previous: ImageTexture = null) -> ImageTexture:
	if snapshot.is_empty():
		return null
	var roi: Rect2i = snapshot["roi"]
	var mask: PackedByteArray = snapshot["mask"]
	var pixels := PackedByteArray()
	pixels.resize(mask.size() * 2)
	pixels.fill(255)
	for index in range(mask.size()):
		pixels[index * 2 + 1] = 0 if mask[index] == 0 else 255
	var image := Image.create_from_data(roi.size.x, roi.size.y, false, Image.FORMAT_LA8, pixels)
	if previous != null and Vector2i(previous.get_size()) == roi.size:
		previous.update(image)
		return previous
	return ImageTexture.create_from_image(image)


func _valid_mask_snapshot(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var roi: Variant = value.get("roi")
	var mask: Variant = value.get("mask")
	if not roi is Rect2i or not mask is PackedByteArray:
		return {}
	if roi.size.x <= 0 or roi.size.y <= 0 or roi.size.x * roi.size.y != mask.size():
		return {}
	return {"roi": roi, "mask": mask.duplicate()}


func _valid_transform() -> bool:
	return _transform is Object and _transform.has_method("is_configured") and _transform.is_configured()
