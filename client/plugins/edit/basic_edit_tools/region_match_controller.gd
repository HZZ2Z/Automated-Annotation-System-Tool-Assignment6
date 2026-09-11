extends RefCounted

const GEOMETRY := preload("res://client/domain/region_geometry.gd")
const SOLVER := preload("res://client/domain/region_match_solver.gd")
const COMMAND := preload("res://client/domain/commands/match_region_command.gd")
const SOURCE_COLOR := Color("#f59e0b")
const REFERENCE_COLOR := Color("#22d3ee")
const CLICK_TRAVEL_VIEWPORT_PX := 4.0
const INITIAL_HINT := "点击待修正区域"

var source_id := ""
var message := INITIAL_HINT
var _frame := -1
var _before: Dictionary = {}
var _hover_id := ""
var _pressed_id := ""
var _press_position := Vector2.ZERO
var _press_frame := -1
var _press_record: Dictionary = {}
var _dragged := false
var _cached_frame := -1
var _cached_revision := -1
var _cached_record: Dictionary = {}
var _hit_order: Array[Dictionary] = []


# 只持有当前两次点击的临时状态；Store 修改始终交给独立命令。
func clear() -> void:
	source_id = ""
	message = INITIAL_HINT
	_frame = -1
	_before = {}
	_hover_id = ""
	_clear_press()
	_cached_frame = -1
	_cached_revision = -1
	_cached_record = {}
	_hit_order.clear()


func has_pending() -> bool:
	return not source_id.is_empty() or _press_frame >= 0


func phase() -> StringName:
	return &"idle" if source_id.is_empty() else &"awaiting_reference"


func refresh(host: Variant) -> void:
	var record := _current_record(host)
	_check_snapshot(host, record)
	# 坐标变换或外部刷新后等待新的命中，避免保留旧位置的候选。
	_hover_id = ""
	_publish(host, record)


func clear_hover(host: Variant) -> void:
	if _hover_id.is_empty():
		return
	_hover_id = ""
	_publish(host, _current_record(host))


func pointer(host: Variant, event: InputEvent, point: Vector2) -> void:
	var record := _current_record(host)
	if not _check_snapshot(host, record):
		_publish(host, record)
		return
	if event is InputEventMouseMotion:
		if _press_frame >= 0:
			_dragged = _dragged or event.position.distance_to(_press_position) > CLICK_TRAVEL_VIEWPORT_PX
			return
		var hit := _pick(point)
		_hover_id = str(hit.get("id", ""))
		if _hover_id == source_id:
			_hover_id = ""
		_publish(host, record)
		return
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		_clear_press()
		if record.is_empty() or host._current_image_size() == Vector2.ZERO:
			return
		_pressed_id = str(_pick(point).get("id", ""))
		_press_position = event.position
		_press_frame = host._current_frame()
		_press_record = record.duplicate(true)
		host._emit_edit_state()
		return
	var clicked_id := str(_pick(point).get("id", ""))
	var is_click: bool = _press_frame >= 0 and not _dragged \
		and event.position.distance_to(_press_position) <= CLICK_TRAVEL_VIEWPORT_PX \
		and not clicked_id.is_empty() and clicked_id == _pressed_id
	_clear_press()
	if not is_click or clicked_id == source_id:
		_publish(host, record)
		return
	if source_id.is_empty():
		source_id = clicked_id
		_frame = host._current_frame()
		_before = record.duplicate(true)
		_hover_id = ""
		message = "已选待修正区域 %s；点击参考区域" % source_id
		host._set_selected_region(source_id)
		_publish(host, record)
		return
	var corrected_id := source_id
	var command = COMMAND.new(_frame, _before, source_id, clicked_id, host._current_image_size())
	var frozen_frame := _frame
	# Store 会同步通知订阅者；提交前结束待选状态，避免把自己的提交判为外部变化。
	clear()
	var errors: PackedStringArray = host._execute(command, frozen_frame)
	message = command.message if errors.is_empty() else errors[0]
	if errors.is_empty():
		host._set_selected_region(clicked_id if command.outcome == &"merged" else corrected_id)
	_publish(host, _current_record(host))


func _clear_press() -> void:
	_pressed_id = ""
	_press_frame = -1
	_press_record = {}
	_dragged = false


func _check_snapshot(host: Variant, record: Dictionary) -> bool:
	var frame: int = host._current_frame()
	if ((not source_id.is_empty() and (frame != _frame or record != _before))
			or (_press_frame >= 0 and (frame != _press_frame or record != _press_record))):
		clear()
		message = "区域记录已变化，请重新点击待修正区域"
		return false
	return true


func _current_record(host: Variant) -> Dictionary:
	var frame: int = host._current_frame()
	var revision: int = host._store.current_revision() if host._store.has_method("current_revision") else -1
	if revision >= 0 and frame == _cached_frame and revision == _cached_revision:
		return _cached_record
	_cached_frame = frame
	_cached_revision = revision
	_cached_record = host._record_for_frame(frame)
	_hit_order.clear()
	var regions: Array = _cached_record.get("regions", [])
	for index in range(regions.size()):
		var region: Dictionary = regions[index]
		var area := SOLVER.polygon_area(SOLVER.polygon_for_region(region))
		if not is_finite(area):
			continue
		_hit_order.append({"region": region, "area": area, "order": index, "bounds": GEOMETRY.image_bounds(region)})
	# 面积排序只在记录变化时更新；同面积按最后绘制者优先。
	_hit_order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.area < b.area if a.area != b.area else a.order > b.order)
	return _cached_record


func _pick(point: Vector2) -> Dictionary:
	for candidate: Dictionary in _hit_order:
		var bounds: Rect2 = candidate.bounds
		if (point.x < bounds.position.x or point.y < bounds.position.y
				or point.x > bounds.end.x or point.y > bounds.end.y):
			continue
		if GEOMETRY.contains(candidate.region, point):
			return candidate.region
	return {}


func _publish(host: Variant, record: Dictionary) -> void:
	var highlights: Array[Dictionary] = []
	var source: Dictionary = host._find_region(record, source_id)
	var hovered: Dictionary = host._find_region(record, _hover_id)
	if not source.is_empty():
		highlights.append(_highlight(source, SOURCE_COLOR, "A · 待修正"))
	if not hovered.is_empty():
		highlights.append(_highlight(hovered, SOURCE_COLOR if source_id.is_empty() else REFERENCE_COLOR,
			"待修正" if source_id.is_empty() else "B · 参考"))
	if highlights.is_empty():
		host._viewport.clear_edit_overlay()
	else:
		host._viewport.set_edit_overlay({"region_highlights": highlights, "suppress_region_id": source_id})
	var hint := message
	if not source_id.is_empty() and not hovered.is_empty():
		hint = "点击参考区域 %s：%s / %s" % [hovered.id, hovered["class"], hovered.kind]
	host._emit_edit_state()
	host._report(hint)


func _highlight(region: Dictionary, color: Color, role: String) -> Dictionary:
	return {"region_id": region.id, "polygon": SOLVER.polygon_for_region(region), "color": color,
		"label": "%s · %s / %s" % [role, region["class"], region.kind]}
