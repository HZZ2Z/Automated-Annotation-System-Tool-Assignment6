extends "res://client/pipeline/stages/render_stage.gd"

const REGION_GEOMETRY := preload("res://client/domain/region_geometry.gd")
const CLASS_COLOR_RESOLVER := preload("res://client/domain/class_color_resolver.gd")
const TAXONOMY_PATH := "res://core/taxonomy/classes.json"
const NORMAL_LINE_WIDTH := 2.0
const HOVER_LINE_WIDTH := 3.0
const SELECTED_LINE_WIDTH := 4.0
const HANDLE_SIZE := 7.0
const LABEL_FONT_SIZE := 14
const LABEL_PADDING := Vector2(4.0, 3.0)
const LABEL_BACKGROUND := Color(0.02, 0.02, 0.02, 0.82)

var _texture: Texture2D
var _color_resolver
var _transform
var _selected_id := ""
var _hovered_id := ""
var _suppressed_region_id := ""
var _opacity := 0.35
var _record_snapshot: Dictionary = {}
var _record_hash := 0
var _has_record_snapshot := false
var _primitives: Array[Dictionary] = []
var _overlay_commands: Array[Dictionary] = []
var _geometry_rebuilds := 0
var _screen_rebuilds := 0


func _init() -> void:
	_color_resolver = CLASS_COLOR_RESOLVER.new(_read_taxonomy())


func set_state(texture: Texture2D, record: Dictionary, transform, selected_id: String, opacity: float) -> void:
	_texture = texture
	_transform = transform
	_selected_id = selected_id
	_opacity = clampf(opacity, 0.0, 1.0) if is_finite(opacity) else 0.35
	var next_hash := hash(record)
	if not _has_record_snapshot or next_hash != _record_hash or _record_snapshot != record:
		_record_snapshot = record.duplicate(true)
		_record_hash = next_hash
		_has_record_snapshot = true
		_rebuild_geometry_cache()
	_rebuild_screen_commands()


func set_hovered_region_id(region_id: String) -> void:
	if _hovered_id == region_id:
		return
	_hovered_id = region_id
	_rebuild_screen_commands()


func set_suppressed_region_id(region_id: String) -> void:
	if _suppressed_region_id == region_id:
		return
	_suppressed_region_id = region_id
	_rebuild_screen_commands()


func draw(canvas: CanvasItem) -> void:
	if canvas == null or _transform == null or not _transform.is_configured():
		return
	if _texture != null:
		var image_top_left: Vector2 = _transform.image_to_viewport(Vector2.ZERO)
		var image_bottom_right: Vector2 = _transform.image_to_viewport(_transform.image_size)
		canvas.draw_texture_rect(_texture, Rect2(image_top_left, image_bottom_right - image_top_left), false)
	for command: Dictionary in _overlay_commands:
		_draw_overlay(canvas, command)


func hit_test(image_point: Vector2) -> Dictionary:
	for index in range(_primitives.size() - 1, -1, -1):
		var primitive: Dictionary = _primitives[index]
		var region: Dictionary = primitive["region"]
		if REGION_GEOMETRY.contains(region, image_point):
			return region.duplicate(true)
	return {}


func get_overlay_descriptions() -> Array[Dictionary]:
	return _overlay_commands.duplicate(true)


func get_cache_stats() -> Dictionary:
	return {
		"geometry_rebuilds": _geometry_rebuilds,
		"screen_rebuilds": _screen_rebuilds,
		"primitive_count": _primitives.size(),
		"visible_count": _overlay_commands.size(),
	}


func _rebuild_geometry_cache() -> void:
	_geometry_rebuilds += 1
	_primitives.clear()
	var regions: Variant = _record_snapshot.get("regions", [])
	if not regions is Array:
		return
	for value: Variant in regions:
		if not value is Dictionary:
			continue
		var region: Dictionary = value
		var shape: StringName = REGION_GEOMETRY.canonical_shape(region)
		if shape == REGION_GEOMETRY.SHAPE_NONE:
			continue
		var primitive := {
			"region": region,
			"shape": shape,
			"bounds": REGION_GEOMETRY.image_bounds(region),
			"color": _class_color(str(region.get("class", "unknown"))),
			"label": _region_label(region),
		}
		if shape == REGION_GEOMETRY.SHAPE_POLYGON:
			primitive["points"] = REGION_GEOMETRY.polygon_points(region)
		else:
			primitive["box"] = REGION_GEOMETRY.box_rect(region)
		_primitives.append(primitive)


func _rebuild_screen_commands() -> void:
	_screen_rebuilds += 1
	_overlay_commands.clear()
	if _transform == null or not _transform.is_configured():
		return
	for primitive: Dictionary in _primitives:
		if str(primitive["region"].get("id", "")) == _suppressed_region_id:
			continue
		if not _primitive_is_visible(primitive):
			continue
		var command := _screen_command(primitive)
		if not command.is_empty():
			_overlay_commands.append(command)


func _primitive_is_visible(primitive: Dictionary) -> bool:
	var image_bounds: Rect2 = primitive["bounds"]
	var top_left: Vector2 = _transform.image_to_viewport(image_bounds.position)
	var bottom_right: Vector2 = _transform.image_to_viewport(image_bounds.end)
	var viewport_bounds := Rect2(top_left, bottom_right - top_left).abs()
	return _transform.viewport_rect.intersects(viewport_bounds, true)


func _screen_command(primitive: Dictionary) -> Dictionary:
	var region: Dictionary = primitive["region"]
	var selected := str(region.get("id", "")) == _selected_id
	var hovered := not selected and str(region.get("id", "")) == _hovered_id
	var outline_color: Color = primitive["color"]
	if hovered:
		outline_color = outline_color.darkened(0.18)
	outline_color.a = 1.0
	var fill_color := outline_color
	fill_color.a = 1.0 if selected else (maxf(_opacity, 0.65) if hovered else _opacity)
	var command := {
		"id": str(region.get("id", "")),
		"shape": String(primitive["shape"]),
		"color": outline_color,
		"fill_color": fill_color,
		"fill": selected or bool(region.get("filled", true)),
		"selected": selected,
		"hovered": hovered,
		"line_width": SELECTED_LINE_WIDTH if selected else (HOVER_LINE_WIDTH if hovered else NORMAL_LINE_WIDTH),
		"label": primitive["label"],
		"label_color": Color.WHITE,
	}
	var label_anchor := Vector2.ZERO
	if primitive["shape"] == REGION_GEOMETRY.SHAPE_BOX:
		var image_box: Rect2 = primitive["box"]
		var top_left: Vector2 = _transform.image_to_viewport(image_box.position)
		var bottom_right: Vector2 = _transform.image_to_viewport(image_box.end)
		var viewport_box := Rect2(top_left, bottom_right - top_left).abs()
		command["rect"] = viewport_box
		command["handles"] = _box_handles(viewport_box) if selected else PackedVector2Array()
		label_anchor = viewport_box.position
	else:
		var viewport_points := PackedVector2Array()
		for point: Vector2 in primitive["points"]:
			viewport_points.append(_transform.image_to_viewport(point))
		if viewport_points.size() < 3:
			return {}
		var outline := viewport_points.duplicate()
		outline.append(viewport_points[0])
		command["points"] = viewport_points
		command["outline"] = outline
		command["handles"] = _box_handles(_points_bounds(viewport_points)) if selected else PackedVector2Array()
		label_anchor = _polygon_label_anchor(viewport_points)
	_add_label_layout(command, label_anchor)
	return command


func _add_label_layout(command: Dictionary, anchor: Vector2) -> void:
	var font := ThemeDB.fallback_font
	var label: String = command["label"]
	var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, LABEL_FONT_SIZE)
	var background_size := Vector2(text_size.x + LABEL_PADDING.x * 2.0, font.get_height(LABEL_FONT_SIZE) + LABEL_PADDING.y * 2.0)
	background_size.x = minf(background_size.x, _transform.viewport_rect.size.x)
	background_size.y = minf(background_size.y, _transform.viewport_rect.size.y)
	var background_position := anchor + Vector2(0.0, -background_size.y - 4.0)
	var maximum_position: Vector2 = _transform.viewport_rect.end - background_size
	background_position.x = clampf(background_position.x, _transform.viewport_rect.position.x, maxf(_transform.viewport_rect.position.x, maximum_position.x))
	background_position.y = clampf(background_position.y, _transform.viewport_rect.position.y, maxf(_transform.viewport_rect.position.y, maximum_position.y))
	command["label_background"] = Rect2(background_position, background_size)
	command["label_position"] = background_position + Vector2(LABEL_PADDING.x, LABEL_PADDING.y + font.get_ascent(LABEL_FONT_SIZE))


func _draw_overlay(canvas: CanvasItem, command: Dictionary) -> void:
	var color: Color = command["color"]
	var fill_color: Color = command["fill_color"]
	var line_width: float = command["line_width"]
	if command["shape"] == "box":
		var rect: Rect2 = command["rect"]
		if command["fill"] and fill_color.a > 0.0:
			canvas.draw_rect(rect, fill_color, true)
		canvas.draw_rect(rect, color, false, line_width, true)
	else:
		var points: PackedVector2Array = command["points"]
		if command["fill"] and fill_color.a > 0.0:
			canvas.draw_colored_polygon(points, fill_color)
		canvas.draw_polyline(command["outline"], color, line_width, true)
	var label_background: Rect2 = command["label_background"]
	canvas.draw_rect(label_background, LABEL_BACKGROUND, true)
	canvas.draw_rect(label_background, color, false, 1.0, true)
	canvas.draw_string(ThemeDB.fallback_font, command["label_position"], command["label"], HORIZONTAL_ALIGNMENT_LEFT, -1.0, LABEL_FONT_SIZE, command["label_color"])
	for handle_position: Vector2 in command["handles"]:
		canvas.draw_rect(Rect2(handle_position - Vector2.ONE * HANDLE_SIZE * 0.5, Vector2.ONE * HANDLE_SIZE), color, true)


func _box_handles(rect: Rect2) -> PackedVector2Array:
	var center := rect.get_center()
	return PackedVector2Array([
		rect.position,
		Vector2(center.x, rect.position.y),
		Vector2(rect.end.x, rect.position.y),
		Vector2(rect.end.x, center.y),
		rect.end,
		Vector2(center.x, rect.end.y),
		Vector2(rect.position.x, rect.end.y),
		Vector2(rect.position.x, center.y),
	])


func _points_bounds(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var minimum := points[0]
	var maximum := points[0]
	for point: Vector2 in points:
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	return Rect2(minimum, maximum - minimum)


func _polygon_label_anchor(points: PackedVector2Array) -> Vector2:
	var position := points[0]
	for point: Vector2 in points:
		position.x = minf(position.x, point.x)
		position.y = minf(position.y, point.y)
	return position


func _region_label(region: Dictionary) -> String:
	var label := str(region.get("class", "unknown"))
	if region.has("conf") and _finite_number(region["conf"]):
		label += " %.2f" % float(region["conf"])
	return label


func _class_color(class_id: String) -> Color:
	return _color_resolver.color_for(class_id)


func _read_taxonomy() -> Dictionary:
	var file := FileAccess.open(TAXONOMY_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return {}
	return parsed


func _finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
