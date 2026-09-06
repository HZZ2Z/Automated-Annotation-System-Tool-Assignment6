extends RefCounted

const GEOMETRY := preload("res://client/domain/region_geometry.gd")
const POLYGONS := preload("res://client/domain/polygon_ops.gd")
const REPLACE := preload("res://client/domain/commands/replace_region_geometry_command.gd")
const HIT_RADIUS := 8.0 # 视口像素：缩放后控制点仍然容易命中。

var region_id := ""
var frame := -1
var active_vertex := 0
var dragging := false
var _before: Dictionary = {}
var _preview := PackedVector2Array()
var _press_point := Vector2.ZERO
var _moved := false


func clear() -> void:
	region_id = ""
	frame = -1
	active_vertex = 0
	dragging = false
	_before = {}
	_preview = PackedVector2Array()


func refresh(host: Variant) -> bool:
	if dragging:
		return true
	var current_frame: int = host._current_frame()
	var selected: String = host._selected_region_id()
	var region: Dictionary = host._find_region(host._record_for_frame(current_frame), selected)
	if GEOMETRY.canonical_shape(region) != GEOMETRY.SHAPE_POLYGON:
		if not region_id.is_empty():
			clear()
			host._viewport.clear_edit_overlay()
		return false
	if frame != current_frame or region_id != selected:
		active_vertex = 0
	frame = current_frame
	region_id = selected
	_preview = host._region_polygon(region)
	active_vertex = clampi(active_vertex, 0, _preview.size() - 1)
	_show(host)
	return true


func pointer(host: Variant, event: InputEvent, point: Vector2) -> bool:
	if region_id.is_empty():
		return false
	if dragging:
		if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if not point.is_equal_approx(_press_point):
				_moved = true
			if _moved:
				_preview[active_vertex] = point
				_show(host)
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			dragging = false
			if _moved or not point.is_equal_approx(_press_point):
				_preview[active_vertex] = point
				_commit(host, _preview)
			else:
				_before = {}
				refresh(host)
		return true
	if not refresh(host):
		return false
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT or not event.pressed:
		return true
	var transform: Variant = host._viewport.get_image_transform()
	var screen: Vector2 = transform.image_to_viewport(point)
	var closest := -1
	var distance := HIT_RADIUS
	for index in range(_preview.size()):
		var d: float = screen.distance_to(transform.image_to_viewport(_preview[index]))
		if d <= distance:
			closest = index
			distance = d
	if closest >= 0:
		active_vertex = closest
		_before = host._record_for_frame(frame).duplicate(true)
		_press_point = point
		_moved = false
		dragging = true
		_show(host)
		return true
	var edge := -1
	var projected := Vector2.ZERO
	distance = HIT_RADIUS
	for index in range(_preview.size()):
		var a: Vector2 = transform.image_to_viewport(_preview[index])
		var b: Vector2 = transform.image_to_viewport(_preview[(index + 1) % _preview.size()])
		var nearest := Geometry2D.get_closest_point_to_segment(screen, a, b)
		var d := screen.distance_to(nearest)
		if d <= distance:
			edge = index
			distance = d
			projected = transform.viewport_to_image(nearest)
	if edge >= 0:
		if event.double_click:
			_before = host._record_for_frame(frame).duplicate(true)
			var points := _preview.duplicate()
			points.insert(edge + 1, projected)
			active_vertex = edge + 1
			_commit(host, points)
		return true
	if Geometry2D.is_point_in_polygon(point, _preview):
		return true
	# 空白处开始原有新建流程；释放事件交回 Lasso 自身处理。
	clear()
	host._vertex_mode_requested = false
	host._set_selected_region("")
	host._viewport.clear_edit_overlay()
	return false


func key(host: Variant, event: InputEventKey, code: Key) -> bool:
	if region_id.is_empty():
		return false
	if dragging:
		return code != KEY_TAB
	if not refresh(host):
		return false
	if code in [KEY_BRACKETLEFT, KEY_BRACKETRIGHT] and not event.ctrl_pressed and not event.alt_pressed:
		active_vertex = posmod(active_vertex + (-1 if code == KEY_BRACKETLEFT else 1), _preview.size())
		_show(host)
		return true
	var points := _preview.duplicate()
	var direction: Vector2 = host._arrow_direction(code)
	if direction != Vector2.ZERO and not event.alt_pressed:
		points[active_vertex] += direction * host._key_step(event)
	elif code == KEY_INSERT and not event.ctrl_pressed and not event.alt_pressed:
		var midpoint := (points[active_vertex] + points[(active_vertex + 1) % points.size()]) * 0.5
		points.insert(active_vertex + 1, midpoint)
		active_vertex += 1
	elif code in [KEY_DELETE, KEY_BACKSPACE] and not event.ctrl_pressed and not event.alt_pressed:
		if points.size() <= 3:
			host._report("Vertex edit refused: a polygon needs at least three vertices")
			return true
		points.remove_at(active_vertex)
	else:
		return false
	_before = host._record_for_frame(frame).duplicate(true)
	_commit(host, points)
	return true


func _commit(host: Variant, points: PackedVector2Array) -> void:
	# 拖动冻结整帧快照，避免后台更新或换帧后写回过期几何。
	if host._current_frame() != frame or host._selected_region_id() != region_id or host._record_for_frame(frame) != _before:
		host._report("Vertex edit refused: frame or annotation changed during the gesture")
		clear()
		host._viewport.clear_edit_overlay()
		host._emit_edit_state()
		return
	if points.size() > POLYGONS.MAX_PIXEL_BOUNDARY_VERTICES or not POLYGONS.validate_simple_polygon(points):
		host._report("Vertex edit refused: polygon must have distinct vertices, nonzero area and no self-intersections (maximum 2048 vertices)")
	elif not POLYGONS.points_fit_image(points, host._current_image_size()):
		host._report("Vertex edit refused: geometry must stay inside the current image")
	else:
		host._execute(REPLACE.new(frame, _before, region_id, points, host._current_image_size()), frame)
	_before = {}
	refresh(host)
	host._emit_edit_state()


func _show(host: Variant) -> void:
	var path := _preview.duplicate()
	if not path.is_empty():
		path.append(path[0])
	host._viewport.set_edit_overlay({
		"tool_id": &"lasso", "phase": &"vertex_edit",
		"path": path, "vertex_points": _preview,
		"active_vertex": active_vertex,
		"vertex_edit_region_id": region_id,
		"suppress_region_id": region_id if dragging else "",
	})
	host._emit_edit_state()
