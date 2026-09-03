class_name AnnotationTimeline
extends Control

signal frame_requested(index: int)

@export var cell_width := 18.0

@onready var _scroll_bar: HScrollBar = $ScrollBar

var _frame_count := 0
var _current_frame := -1
var _verified := PackedByteArray()
var _in_batch := PackedByteArray()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_scroll_bar.value_changed.connect(_on_scroll_changed)
	_update_scroll_bar()


func configure(frame_count: int) -> void:
	_frame_count = maxi(0, frame_count)
	_current_frame = 0 if _frame_count > 0 else -1
	_verified = PackedByteArray()
	_verified.resize(_frame_count)
	_verified.fill(0)
	_in_batch = PackedByteArray()
	_in_batch.resize(_frame_count)
	_in_batch.fill(0)
	if is_node_ready():
		_scroll_bar.value = 0.0
		_update_scroll_bar()
	queue_redraw()


func set_current_frame(index: int) -> bool:
	if index < 0 or index >= _frame_count:
		return false
	_current_frame = index
	_ensure_current_visible()
	queue_redraw()
	return true


func set_verified(index: int, value: bool) -> bool:
	if index < 0 or index >= _frame_count:
		return false
	_verified[index] = 1 if value else 0
	queue_redraw()
	return true


func set_batch_ranges(ranges: Array) -> void:
	_in_batch.fill(0)
	if _frame_count <= 0:
		queue_redraw()
		return
	for value: Variant in ranges:
		if not value is Dictionary:
			continue
		var marker: Dictionary = value
		if not marker.has("start_frame") or not marker.has("end_frame"):
			continue
		var start_value: Variant = marker["start_frame"]
		var end_value: Variant = marker["end_frame"]
		if not _is_integer(start_value) or not _is_integer(end_value):
			continue
		var start_frame := int(start_value)
		var end_frame := int(end_value)
		if start_frame > end_frame or end_frame < 0 or start_frame >= _frame_count:
			continue
		start_frame = clampi(start_frame, 0, _frame_count - 1)
		end_frame = clampi(end_frame, 0, _frame_count - 1)
		for index in range(start_frame, end_frame + 1):
			_in_batch[index] = 1
	queue_redraw()


func get_frame_state(index: int) -> Dictionary:
	if index < 0 or index >= _frame_count:
		return {}
	return {
		"current": index == _current_frame,
		"verified": _verified[index] != 0,
		"in_batch": _in_batch[index] != 0,
	}


func get_visible_frame_indices(view_width: float, scroll_value: float) -> PackedInt32Array:
	var result := PackedInt32Array()
	if _frame_count <= 0 or cell_width <= 0.0 or not is_finite(view_width) or view_width <= 0.0 or not is_finite(scroll_value):
		return result
	var start := clampi(floori(scroll_value), 0, _frame_count - 1)
	var visible_count := ceili(view_width / cell_width)
	var finish := mini(_frame_count, start + visible_count)
	for index in range(start, finish):
		result.append(index)
	return result


func _draw() -> void:
	if _frame_count <= 0 or cell_width <= 0.0:
		return
	var strip_height := maxf(1.0, size.y - _scroll_bar.size.y - 2.0)
	var start := clampi(floori(_scroll_bar.value), 0, _frame_count - 1)
	for index in get_visible_frame_indices(size.x, _scroll_bar.value):
		var x := float(index - start) * cell_width
		var rect := Rect2(x + 1.0, 1.0, maxf(1.0, cell_width - 2.0), maxf(1.0, strip_height - 2.0))
		var fill := Color("#3f8f65") if _verified[index] != 0 else Color("#75565d")
		draw_rect(rect, fill, true)
		if _in_batch[index] != 0:
			draw_rect(rect.grow(-1.0), Color("#e0a84b"), false, 2.0)
		if index == _current_frame:
			draw_rect(rect, Color("#f4f4f5"), false, 3.0)


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton:
		return
	if event.button_index != MOUSE_BUTTON_LEFT or not event.pressed or cell_width <= 0.0:
		return
	if event.position.y >= size.y - _scroll_bar.size.y:
		return
	var index := floori(_scroll_bar.value) + floori(event.position.x / cell_width)
	if index >= 0 and index < _frame_count:
		frame_requested.emit(index)
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready():
		_update_scroll_bar()
		queue_redraw()


func _on_scroll_changed(_value: float) -> void:
	queue_redraw()


func _update_scroll_bar() -> void:
	if not is_node_ready():
		return
	var visible_frames := maxf(1.0, floorf(size.x / maxf(cell_width, 1.0)))
	_scroll_bar.min_value = 0.0
	_scroll_bar.max_value = float(_frame_count)
	_scroll_bar.page = minf(float(_frame_count), visible_frames)
	_scroll_bar.step = 1.0
	_scroll_bar.visible = _frame_count > int(visible_frames)


func _ensure_current_visible() -> void:
	if not is_node_ready() or not _scroll_bar.visible or _current_frame < 0:
		return
	var first := floori(_scroll_bar.value)
	var visible_frames := maxi(1, floori(size.x / maxf(cell_width, 1.0)))
	if _current_frame < first:
		_scroll_bar.value = float(_current_frame)
	elif _current_frame >= first + visible_frames:
		_scroll_bar.value = float(_current_frame - visible_frames + 1)


func _is_integer(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and float(value) == floorf(float(value))
