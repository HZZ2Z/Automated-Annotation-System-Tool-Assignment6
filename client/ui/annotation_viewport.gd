class_name AnnotationViewport
extends Control

signal region_selected(region_id: String)
signal image_pointer_event(event: InputEvent, image_position: Vector2)
signal transform_changed
signal edit_cancel_requested
signal selection_cancel_requested

const TRANSFORM_SCRIPT := preload("res://client/services/viewport_transform.gd")
const RENDERER_SCRIPT := preload("res://client/pipeline/null_renderer.gd")
const WHEEL_ZOOM_FACTOR := 1.1

var _viewport_transform = TRANSFORM_SCRIPT.new()
var _renderer = RENDERER_SCRIPT.new()
var _texture: Texture2D
var _current_image: Image
var _current_image_capture_count := 0
var _record: Dictionary = {}
var _selected_id := ""
var _hovered_id := ""
var _opacity := 0.35
var _pan_button := MOUSE_BUTTON_NONE
var _left_edit_active := false
var _edit_selection_authoritative := false
var _last_transform_signature: Array = []
var _edit_overlay_state: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	if _configure_transform():
		transform_changed.emit()
	_sync_renderer()
	_sync_edit_overlay()


func set_renderer(renderer: Variant) -> void:
	if not renderer is Object or renderer == null:
		return
	for method: String in ["set_state", "draw", "hit_test"]:
		if not renderer.has_method(method):
			return
	_renderer = renderer
	_sync_renderer()
	_sync_suppressed_region_to_renderer()
	_sync_hover_to_renderer()
	queue_redraw()


func set_texture(texture: Texture2D) -> void:
	var texture_identity_changed := _texture != texture
	_refresh_current_image(texture)
	if not texture_identity_changed and _image_dimensions_match_configured_transform():
		return
	_texture = texture
	var transform_did_change := _configure_transform()
	_sync_renderer()
	if transform_did_change:
		_sync_edit_overlay_transform()
	queue_redraw()
	if transform_did_change:
		transform_changed.emit()


func set_record(record: Dictionary) -> void:
	if _record == record:
		return
	_record = record.duplicate(true)
	var transform_did_change := _configure_transform()
	_sync_renderer()
	if transform_did_change:
		_sync_edit_overlay_transform()
	queue_redraw()
	if transform_did_change:
		transform_changed.emit()


func set_selected_region_id(region_id: String) -> void:
	if _selected_id == region_id:
		return
	_selected_id = region_id
	_sync_renderer()
	queue_redraw()


func set_hovered_region_id(region_id: String) -> void:
	if _hovered_id == region_id:
		return
	_hovered_id = region_id
	_sync_hover_to_renderer()
	queue_redraw()


func get_hovered_region_id() -> String:
	return _hovered_id


func set_overlay_opacity(opacity: float) -> void:
	var next_opacity := clampf(opacity, 0.0, 1.0) if is_finite(opacity) else 0.35
	if is_equal_approx(_opacity, next_opacity):
		return
	_opacity = next_opacity
	_sync_renderer()
	queue_redraw()


func set_state(texture: Texture2D, record: Dictionary, selected_id: String, opacity: float) -> void:
	var next_opacity := clampf(opacity, 0.0, 1.0) if is_finite(opacity) else 0.35
	var texture_identity_changed := _texture != texture
	_refresh_current_image(texture)
	if (not texture_identity_changed and _record == record and _selected_id == selected_id
			and is_equal_approx(_opacity, next_opacity) and _image_dimensions_match_configured_transform()):
		return
	_texture = texture
	_record = record.duplicate(true)
	_selected_id = selected_id
	_opacity = next_opacity
	var transform_did_change := _configure_transform()
	_sync_renderer()
	if transform_did_change:
		_sync_edit_overlay_transform()
	queue_redraw()
	if transform_did_change:
		transform_changed.emit()


func get_image_transform():
	return _viewport_transform


func get_current_image() -> Image:
	return _current_image


func set_edit_selection_authoritative(value: bool) -> void:
	_edit_selection_authoritative = value


func set_edit_overlay(state: Dictionary) -> void:
	_edit_overlay_state = state.duplicate(true)
	_sync_suppressed_region_to_renderer()
	_sync_edit_overlay()
	queue_redraw()


func clear_edit_overlay() -> void:
	if _edit_overlay_state.is_empty():
		return
	_edit_overlay_state = {}
	_sync_suppressed_region_to_renderer()
	_sync_edit_overlay()
	queue_redraw()


func get_edit_overlay_state() -> Dictionary:
	return _edit_overlay_state.duplicate(true)


func notify_transform_changed() -> void:
	if not _viewport_transform.is_configured():
		return
	if _last_transform_signature == _transform_signature():
		return
	_sync_renderer()
	_sync_edit_overlay_transform()
	queue_redraw()
	transform_changed.emit()


func reset_view_to_fit() -> bool:
	if not _viewport_transform.reset_to_fit():
		return false
	notify_transform_changed()
	return true


func _draw() -> void:
	_renderer.draw(self)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_pan_button = MOUSE_BUTTON_NONE
			_left_edit_active = false
		NOTIFICATION_RESIZED:
			if _viewport_transform == null or _renderer == null:
				return
			if _configure_transform():
				_sync_renderer()
				_sync_edit_overlay_transform()
				queue_redraw()
				transform_changed.emit()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
		return
	if event is InputEventMouseMotion:
		_handle_mouse_motion(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if event.pressed and _viewport_transform.is_configured():
			var factor := WHEEL_ZOOM_FACTOR if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / WHEEL_ZOOM_FACTOR
			_viewport_transform.zoom_at(event.position, factor)
			notify_transform_changed()
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			_pan_button = MOUSE_BUTTON_MIDDLE
		else:
			_pan_button = MOUSE_BUTTON_NONE
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			selection_cancel_requested.emit()
		accept_event()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if not event.pressed:
		if _pan_button == MOUSE_BUTTON_LEFT:
			_pan_button = MOUSE_BUTTON_NONE
			accept_event()
			return
		if _left_edit_active:
			_emit_image_pointer(event, true)
			_left_edit_active = false
		return
	if not _viewport_transform.is_configured():
		return
	if not _viewport_transform.contains_viewport_point(event.position):
		_left_edit_active = false
		region_selected.emit("")
		accept_event()
		return
	_left_edit_active = true
	var image_position: Vector2 = _viewport_transform.viewport_to_image(event.position)
	var hit: Dictionary = _renderer.hit_test(image_position)
	if not _edit_selection_authoritative:
		region_selected.emit(str(hit.get("id", "")))
	image_pointer_event.emit(event, image_position)


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if _pan_button == MOUSE_BUTTON_NONE:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if _left_edit_active:
				_emit_image_pointer(event, true)
		else:
			_emit_image_pointer(event)
		return
	if not _viewport_transform.is_configured():
		return
	_viewport_transform.pan_by(event.relative)
	notify_transform_changed()
	accept_event()

func _emit_image_pointer(event: InputEventMouse, clamp_to_image: bool = false) -> void:
	if not _viewport_transform.is_configured():
		return
	if not clamp_to_image and not _viewport_transform.contains_viewport_point(event.position):
		return
	var image_position: Vector2 = _viewport_transform.viewport_to_image(event.position)
	if clamp_to_image:
		image_position.x = clampf(image_position.x, 0.0, _viewport_transform.image_size.x)
		image_position.y = clampf(image_position.y, 0.0, _viewport_transform.image_size.y)
	image_pointer_event.emit(event, image_position)


func _configure_transform() -> bool:
	var new_image_size := _state_image_size()
	var new_viewport_rect := Rect2(Vector2.ZERO, size)
	if not _valid_size(new_image_size) or not _valid_size(new_viewport_rect.size):
		_left_edit_active = false
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


func _image_dimensions_match_configured_transform() -> bool:
	var current_size := _state_image_size()
	if not _valid_size(current_size):
		return not _viewport_transform.is_configured()
	return _viewport_transform.is_configured() and _viewport_transform.image_size.is_equal_approx(current_size)


func _refresh_current_image(texture: Texture2D) -> void:
	if texture == null:
		_current_image = null
		return
	# Every explicit texture/state submission is a cache invalidation boundary,
	# including a same-identity ImageTexture that may have been updated in place.
	# Pointer events only reuse this detached snapshot and never read back again.
	_current_image_capture_count += 1
	var texture_image := texture.get_image()
	if texture_image == null or texture_image.is_empty():
		_current_image = null
		return
	_current_image = texture_image.duplicate() as Image


func _sync_renderer() -> void:
	_renderer.set_state(_texture, _record, _viewport_transform, _selected_id, _opacity)
	_last_transform_signature = _transform_signature()


func _sync_hover_to_renderer() -> void:
	if _renderer != null and _renderer.has_method("set_hovered_region_id"):
		_renderer.set_hovered_region_id(_hovered_id)


func _sync_suppressed_region_to_renderer() -> void:
	if _renderer != null and _renderer.has_method("set_suppressed_region_id"):
		_renderer.set_suppressed_region_id(str(_edit_overlay_state.get("suppress_region_id", "")))


func _sync_edit_overlay() -> void:
	var overlay := get_node_or_null("EditOverlay")
	if overlay != null and overlay.has_method("set_state"):
		overlay.set_state(_edit_overlay_state, _viewport_transform)


func _sync_edit_overlay_transform() -> void:
	var overlay := get_node_or_null("EditOverlay")
	if overlay != null and overlay.has_method("set_transform"):
		overlay.set_transform(_viewport_transform)


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
