class_name AnnotationViewport
extends Control

signal region_selected(region_id: String)
signal image_pointer_event(event: InputEvent, image_position: Vector2)
signal transform_changed

const TRANSFORM_SCRIPT := preload("res://client/services/viewport_transform.gd")
const RENDERER_SCRIPT := preload("res://client/plugins/render/canvas_region_renderer/plugin.gd")
const WHEEL_ZOOM_FACTOR := 1.1

var _viewport_transform = TRANSFORM_SCRIPT.new()
var _renderer = RENDERER_SCRIPT.new()
var _texture: Texture2D
var _record: Dictionary = {}
var _selected_id := ""
var _opacity := 0.35
var _space_held := false
var _pan_button := MOUSE_BUTTON_NONE
var _last_transform_signature: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	if _configure_transform():
		transform_changed.emit()
	_sync_renderer()


func set_texture(texture: Texture2D) -> void:
	if _texture == texture:
		return
	_texture = texture
	var transform_did_change := _configure_transform()
	_sync_renderer()
	queue_redraw()
	if transform_did_change:
		transform_changed.emit()


func set_record(record: Dictionary) -> void:
	if _record == record:
		return
	_record = record.duplicate(true)
	var transform_did_change := _configure_transform()
	_sync_renderer()
	queue_redraw()
	if transform_did_change:
		transform_changed.emit()


func set_selected_region_id(region_id: String) -> void:
	if _selected_id == region_id:
		return
	_selected_id = region_id
	_sync_renderer()
	queue_redraw()


func set_overlay_opacity(opacity: float) -> void:
	var next_opacity := clampf(opacity, 0.0, 1.0) if is_finite(opacity) else 0.35
	if is_equal_approx(_opacity, next_opacity):
		return
	_opacity = next_opacity
	_sync_renderer()
	queue_redraw()


func set_state(texture: Texture2D, record: Dictionary, selected_id: String, opacity: float) -> void:
	var next_opacity := clampf(opacity, 0.0, 1.0) if is_finite(opacity) else 0.35
	if _texture == texture and _record == record and _selected_id == selected_id and is_equal_approx(_opacity, next_opacity):
		return
	_texture = texture
	_record = record.duplicate(true)
	_selected_id = selected_id
	_opacity = next_opacity
	var transform_did_change := _configure_transform()
	_sync_renderer()
	queue_redraw()
	if transform_did_change:
		transform_changed.emit()


func get_image_transform():
	return _viewport_transform


func notify_transform_changed() -> void:
	if not _viewport_transform.is_configured():
		return
	if _last_transform_signature == _transform_signature():
		return
	_sync_renderer()
	queue_redraw()
	transform_changed.emit()


func _draw() -> void:
	_renderer.draw(self)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_space_held = false
			_pan_button = MOUSE_BUTTON_NONE
		NOTIFICATION_RESIZED:
			if _viewport_transform == null or _renderer == null:
				return
			if _configure_transform():
				_sync_renderer()
				queue_redraw()
				transform_changed.emit()


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		_track_space_state(event)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		_update_space_state(event)
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
		return
	if event is InputEventMouseMotion:
		_handle_mouse_motion(event)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey:
		_update_space_state(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	_emit_image_pointer(event)
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if event.pressed and _viewport_transform.is_configured():
			var factor := WHEEL_ZOOM_FACTOR if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / WHEEL_ZOOM_FACTOR
			_viewport_transform.zoom_at(event.position, factor)
			notify_transform_changed()
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_pan_button = MOUSE_BUTTON_MIDDLE if event.pressed else MOUSE_BUTTON_NONE
		accept_event()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed and _space_held:
		_pan_button = MOUSE_BUTTON_LEFT
		accept_event()
		return
	if not event.pressed:
		if _pan_button == MOUSE_BUTTON_LEFT:
			_pan_button = MOUSE_BUTTON_NONE
			accept_event()
		return
	if not _viewport_transform.is_configured():
		return
	var hit: Dictionary = _renderer.hit_test(_viewport_transform.viewport_to_image(event.position))
	if not hit.is_empty():
		region_selected.emit(str(hit.get("id", "")))


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	_emit_image_pointer(event)
	if _pan_button == MOUSE_BUTTON_NONE or not _viewport_transform.is_configured():
		return
	_viewport_transform.pan_by(event.relative)
	notify_transform_changed()
	accept_event()


func _update_space_state(event: InputEventKey) -> void:
	if _track_space_state(event):
		accept_event()


func _track_space_state(event: InputEventKey) -> bool:
	if event.keycode != KEY_SPACE and event.physical_keycode != KEY_SPACE:
		return false
	_space_held = event.pressed
	if not _space_held and _pan_button == MOUSE_BUTTON_LEFT:
		_pan_button = MOUSE_BUTTON_NONE
	return true


func _emit_image_pointer(event: InputEventMouse) -> void:
	if not _viewport_transform.is_configured():
		return
	image_pointer_event.emit(event, _viewport_transform.viewport_to_image(event.position))


func _configure_transform() -> bool:
	var new_image_size := _state_image_size()
	var new_viewport_rect := Rect2(Vector2.ZERO, size)
	if not _valid_size(new_image_size) or not _valid_size(new_viewport_rect.size):
		if _viewport_transform.is_configured():
			_viewport_transform.configure(Vector2.ZERO, Rect2())
			return true
		return false
	if _viewport_transform.is_configured() and _viewport_transform.image_size.is_equal_approx(new_image_size) and _viewport_transform.viewport_rect == new_viewport_rect:
		return false
	return _viewport_transform.configure(new_image_size, new_viewport_rect)


func _state_image_size() -> Vector2:
	if _texture != null and _texture.get_width() > 0 and _texture.get_height() > 0:
		return Vector2(_texture.get_width(), _texture.get_height())
	var value: Variant = _record.get("image_size")
	if value is Array and value.size() == 2 and _finite_number(value[0]) and _finite_number(value[1]):
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO


func _sync_renderer() -> void:
	_renderer.set_state(_texture, _record, _viewport_transform, _selected_id, _opacity)
	_last_transform_signature = _transform_signature()


func _transform_signature() -> Array:
	return [
		_viewport_transform.is_configured(),
		_viewport_transform.image_size,
		_viewport_transform.viewport_rect,
		_viewport_transform.fit_scale,
		_viewport_transform.user_zoom,
		_viewport_transform.pan,
		_viewport_transform.letterbox_offset,
	]


func _valid_size(value: Vector2) -> bool:
	return value.is_finite() and value.x > 0.0 and value.y > 0.0


func _finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
