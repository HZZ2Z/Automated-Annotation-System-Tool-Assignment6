#负责尚未提交的编辑效果，例如正在画的轮廓、候选多边形、遮罩预览、顶点和笔刷半径圆。
#重点函数是 _draw()、_draw_candidate()、_draw_path()、_draw_mask_preview() 和 _draw_brush_cursor()。它也使用同一套坐标变换，让预览跟随图片缩放和平移
class_name EditOverlay
extends Control

const DRAWING_COLOR := Color("#22d3ee")
const CANDIDATE_COLOR := Color("#22c55e")
const WORKING_MASK_COLOR := Color("#f97316")
const INVALID_COLOR := Color("#ef4444")
const POSITIVE_PROMPT_COLOR := Color("#22c55e")
const NEGATIVE_PROMPT_COLOR := Color("#ef4444")
const PROMPT_BOX_COLOR := Color("#22d3ee")
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
	clip_contents = true


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
	_draw_model_prompts()
	_draw_brush_cursor(color)
	_draw_region_highlights()


# Match 的高亮不进入标注记录；先画参考 B，保证包含关系中的小块 A 仍清晰。
func _draw_region_highlights() -> void:
	var highlights: Array = _state.get("region_highlights", [])
	var font := ThemeDB.fallback_font
	for index in range(highlights.size() - 1, -1, -1):
		var layer: Dictionary = highlights[index]
		var polygon: PackedVector2Array = layer.get("polygon", PackedVector2Array())
		if polygon.size() < 3:
			continue
		var points := _to_viewport_points(polygon)
		var color: Color = layer.get("color", CANDIDATE_COLOR)
		var fill := color
		fill.a = 0.14
		if not Geometry2D.triangulate_polygon(points).is_empty():
			draw_colored_polygon(points, fill)
		var closed := points.duplicate()
		closed.append(points[0])
		draw_polyline(closed, color, 3.0, true)
		var label: String = layer.get("label", "")
		var label_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
		var minimum := points[0]
		for point: Vector2 in points:
			minimum = minimum.min(point)
		var width := minf(label_size.x + 8.0, maxf(0.0, size.x - 8.0))
		var origin := Vector2(clampf(minimum.x, 4.0, maxf(4.0, size.x - width - 4.0)),
			clampf(minimum.y - 25.0, 4.0, maxf(4.0, size.y - 25.0)))
		draw_style_box(_highlight_label_style(color), Rect2(origin, Vector2(width, 22)))
		draw_string(font, origin + Vector2(4, 16), label, HORIZONTAL_ALIGNMENT_LEFT, width - 8, 14, color)


func _highlight_label_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#17202eef")
	style.border_color = color
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	return style


func get_prompt_draw_commands() -> Array:
	return _prompt_draw_commands().duplicate(true)


func _draw_model_prompts() -> void:
	for command: Dictionary in _prompt_draw_commands():
		if command.kind == &"prompt_point":
			var center: Vector2 = command.center
			var point_color: Color = command.color
			draw_circle(center, 7.0, Color("#111827"))
			draw_circle(center, 5.5, point_color)
			draw_line(center + Vector2(-3.0, 0.0), center + Vector2(3.0, 0.0), Color.WHITE, 1.5, true)
			if command.positive:
				draw_line(center + Vector2(0.0, -3.0), center + Vector2(0.0, 3.0), Color.WHITE, 1.5, true)
		elif command.kind == &"prompt_box":
			_draw_dashed_rect(command.rect, command.color)


func _prompt_draw_commands() -> Array:
	var commands: Array = []
	if not _valid_transform():
		return commands
	var positive: Variant = _state.get("positive_points", PackedVector2Array())
	if positive is PackedVector2Array:
		for point: Vector2 in positive:
			if point.is_finite():
				commands.append({"kind": &"prompt_point", "center": _transform.image_to_viewport(point), "positive": true, "glyph": "+", "color": POSITIVE_PROMPT_COLOR})
	var negative: Variant = _state.get("negative_points", PackedVector2Array())
	if negative is PackedVector2Array:
		for point: Vector2 in negative:
			if point.is_finite():
				commands.append({"kind": &"prompt_point", "center": _transform.image_to_viewport(point), "positive": false, "glyph": "-", "color": NEGATIVE_PROMPT_COLOR})
	var box: Variant = _state.get("prompt_box")
	if box is Rect2 and box.size.x > 0.0 and box.size.y > 0.0:
		var top_left: Vector2 = _transform.image_to_viewport(box.position)
		var bottom_right: Vector2 = _transform.image_to_viewport(box.end)
		commands.append({"kind": &"prompt_box", "rect": Rect2(top_left, bottom_right - top_left).abs(), "dashed": true, "color": PROMPT_BOX_COLOR})
	return commands


func _draw_dashed_rect(rect: Rect2, color: Color) -> void:
	var top_left := rect.position
	var top_right := Vector2(rect.end.x, rect.position.y)
	var bottom_right := rect.end
	var bottom_left := Vector2(rect.position.x, rect.end.y)
	for segment: Array in [[top_left, top_right], [top_right, bottom_right], [bottom_right, bottom_left], [bottom_left, top_left]]:
		_draw_dashed_line(segment[0], segment[1], color)


func _draw_dashed_line(start: Vector2, finish: Vector2, color: Color) -> void:
	var length := start.distance_to(finish)
	if length <= 0.0:
		return
	var direction := (finish - start) / length
	var offset := 0.0
	while offset < length:
		var dash_end := minf(offset + 7.0, length)
		draw_line(start + direction * offset, start + direction * dash_end, color, LINE_WIDTH, true)
		offset += 12.0


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
