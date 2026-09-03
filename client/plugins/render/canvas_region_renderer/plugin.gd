extends RefCounted

const TAXONOMY_PATH := "res://core/taxonomy/classes.json"
const DEFAULT_COLOR := Color("#a855f7")
const NORMAL_LINE_WIDTH := 2.0
const SELECTED_LINE_WIDTH := 4.0
const HANDLE_SIZE := 7.0

static var _cached_taxonomy_colors: Dictionary = {}

var _texture: Texture2D
var _record: Dictionary = {}
var _transform
var _selected_id := ""
var _opacity := 0.35


func _init() -> void:
	_ensure_taxonomy_colors()


func set_state(texture: Texture2D, record: Dictionary, transform, selected_id: String, opacity: float) -> void:
	_texture = texture
	_record = record
	_transform = transform
	_selected_id = selected_id
	_opacity = clampf(opacity, 0.0, 1.0) if is_finite(opacity) else 0.35


func draw(canvas: CanvasItem) -> void:
	if canvas == null or _transform == null or not _transform.is_configured():
		return
	if _texture != null:
		var image_top_left: Vector2 = _transform.image_to_viewport(Vector2.ZERO)
		var image_bottom_right: Vector2 = _transform.image_to_viewport(_transform.image_size)
		canvas.draw_texture_rect(_texture, Rect2(image_top_left, image_bottom_right - image_top_left), false)
	for command: Dictionary in get_overlay_descriptions():
		_draw_overlay(canvas, command)


func hit_test(image_point: Vector2) -> Dictionary:
	var regions: Variant = _record.get("regions", [])
	if not regions is Array:
		return {}
	for index in range(regions.size() - 1, -1, -1):
		var value: Variant = regions[index]
		if not value is Dictionary:
			continue
		var region: Dictionary = value
		if _region_contains(region, image_point):
			return region.duplicate(true)
	return {}


func get_overlay_descriptions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _transform == null or not _transform.is_configured():
		return result
	var regions: Variant = _record.get("regions", [])
	if not regions is Array:
		return result
	for value: Variant in regions:
		if not value is Dictionary:
			continue
		var region: Dictionary = value
		var command := _describe_region(region)
		if not command.is_empty():
			result.append(command)
	return result


func _describe_region(region: Dictionary) -> Dictionary:
	var region_id := str(region.get("id", ""))
	var selected := region_id == _selected_id
	var color := _class_color(str(region.get("class", "unknown")))
	color.a = _opacity
	var fill_color := color
	fill_color.a *= 0.25
	var command := {
		"id": region_id,
		"color": color,
		"fill_color": fill_color,
		"fill": bool(region.get("filled", false)),
		"selected": selected,
		"line_width": SELECTED_LINE_WIDTH if selected else NORMAL_LINE_WIDTH,
		"label": _region_label(region),
	}
	var box := _box_rect(region)
	if box.size.x > 0.0 and box.size.y > 0.0:
		var top_left: Vector2 = _transform.image_to_viewport(box.position)
		var bottom_right: Vector2 = _transform.image_to_viewport(box.end)
		var viewport_box := Rect2(top_left, bottom_right - top_left)
		command["shape"] = "box"
		command["rect"] = viewport_box
		command["label_position"] = viewport_box.position + Vector2(0.0, -4.0)
		command["handles"] = _box_handles(viewport_box) if selected else PackedVector2Array()
		return command
	var polygon := _polygon_points(region)
	if polygon.size() < 3:
		return {}
	var viewport_points := PackedVector2Array()
	for point: Vector2 in polygon:
		viewport_points.append(_transform.image_to_viewport(point))
	var outline := viewport_points.duplicate()
	outline.append(viewport_points[0])
	command["shape"] = "polygon"
	command["points"] = viewport_points
	command["outline"] = outline
	command["label_position"] = _polygon_label_position(viewport_points)
	command["handles"] = PackedVector2Array()
	return command


func _draw_overlay(canvas: CanvasItem, command: Dictionary) -> void:
	var color: Color = command["color"]
	var fill_color: Color = command["fill_color"]
	var line_width: float = command["line_width"]
	if command["shape"] == "box":
		var rect: Rect2 = command["rect"]
		if command["fill"]:
			canvas.draw_rect(rect, fill_color, true)
		canvas.draw_rect(rect, color, false, line_width, true)
	else:
		var points: PackedVector2Array = command["points"]
		if command["fill"]:
			canvas.draw_colored_polygon(points, fill_color)
		canvas.draw_polyline(command["outline"], color, line_width, true)
	canvas.draw_string(ThemeDB.fallback_font, command["label_position"], command["label"], HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, color)
	for handle_position: Vector2 in command["handles"]:
		canvas.draw_rect(Rect2(handle_position - Vector2.ONE * HANDLE_SIZE * 0.5, Vector2.ONE * HANDLE_SIZE), color, true)


func _region_contains(region: Dictionary, image_point: Vector2) -> bool:
	var box := _box_rect(region)
	if box.size.x > 0.0 and box.size.y > 0.0:
		return box.has_point(image_point)
	var polygon := _polygon_points(region)
	return polygon.size() >= 3 and _point_in_polygon(image_point, polygon)


func _box_rect(region: Dictionary) -> Rect2:
	var value: Variant = region.get("box")
	if not value is Array or value.size() != 4:
		return Rect2()
	for coordinate: Variant in value:
		if (typeof(coordinate) != TYPE_INT and typeof(coordinate) != TYPE_FLOAT) or not is_finite(float(coordinate)):
			return Rect2()
	var width := float(value[2])
	var height := float(value[3])
	if width <= 0.0 or height <= 0.0:
		return Rect2()
	return Rect2(float(value[0]), float(value[1]), width, height)


func _polygon_points(region: Dictionary) -> PackedVector2Array:
	var result := PackedVector2Array()
	var value: Variant = region.get("polygon")
	if not value is Array:
		return result
	for point_value: Variant in value:
		if not point_value is Array or point_value.size() != 2:
			return PackedVector2Array()
		if not _finite_number(point_value[0]) or not _finite_number(point_value[1]):
			return PackedVector2Array()
		result.append(Vector2(float(point_value[0]), float(point_value[1])))
	return result


func _point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	var inside := false
	var previous := polygon.size() - 1
	for current in range(polygon.size()):
		var a := polygon[previous]
		var b := polygon[current]
		if _point_on_segment(point, a, b):
			return true
		if (a.y > point.y) != (b.y > point.y):
			var crossing_x := (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
			if point.x < crossing_x:
				inside = not inside
		previous = current
	return inside


func _point_on_segment(point: Vector2, start: Vector2, finish: Vector2) -> bool:
	var segment := finish - start
	if segment.length_squared() <= 0.0000000001:
		return point.distance_squared_to(start) <= 0.0000000001
	var relative := point - start
	if absf(segment.cross(relative)) > 0.00001:
		return false
	var projection := relative.dot(segment)
	return projection >= 0.0 and projection <= segment.length_squared()


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


func _polygon_label_position(points: PackedVector2Array) -> Vector2:
	var position := points[0]
	for point: Vector2 in points:
		position.x = minf(position.x, point.x)
		position.y = minf(position.y, point.y)
	return position + Vector2(0.0, -4.0)


func _region_label(region: Dictionary) -> String:
	var label := str(region.get("class", "unknown"))
	if region.has("conf") and _finite_number(region["conf"]):
		label += " %.2f" % float(region["conf"])
	return label


func _class_color(class_id: String) -> Color:
	return _cached_taxonomy_colors.get(class_id, _cached_taxonomy_colors.get("unknown", DEFAULT_COLOR))


func _ensure_taxonomy_colors() -> void:
	if not _cached_taxonomy_colors.is_empty():
		return
	var colors := {"unknown": DEFAULT_COLOR}
	var file := FileAccess.open(TAXONOMY_PATH, FileAccess.READ)
	if file == null:
		_cached_taxonomy_colors = colors
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		_cached_taxonomy_colors = colors
		return
	var classes: Variant = parsed.get("classes", [])
	if classes is Array:
		for value: Variant in classes:
			if not value is Dictionary:
				continue
			var class_id: Variant = value.get("id")
			var color_value: Variant = value.get("color")
			if typeof(class_id) == TYPE_STRING and typeof(color_value) == TYPE_STRING:
				colors[class_id] = Color.from_string(color_value, DEFAULT_COLOR)
	_cached_taxonomy_colors = colors


func _finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
