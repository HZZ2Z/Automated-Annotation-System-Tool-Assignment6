class_name ViewportTransform
extends RefCounted

const MIN_USER_ZOOM := 0.1
const MAX_USER_ZOOM := 20.0

var image_size := Vector2.ZERO
var viewport_rect := Rect2()
var fit_scale := 1.0
var user_zoom := 1.0
var pan := Vector2.ZERO
var letterbox_offset := Vector2.ZERO
var _configured := false


func configure(new_image_size: Vector2, new_viewport_rect: Rect2) -> bool:
	_reset()
	if not _valid_size(new_image_size) or not _valid_size(new_viewport_rect.size):
		return false
	image_size = new_image_size
	viewport_rect = new_viewport_rect
	fit_scale = minf(viewport_rect.size.x / image_size.x, viewport_rect.size.y / image_size.y)
	if not is_finite(fit_scale) or fit_scale <= 0.0:
		_reset()
		return false
	letterbox_offset = (viewport_rect.size - image_size * fit_scale) * 0.5
	_configured = true
	return true


func is_configured() -> bool:
	return _configured


func image_to_viewport(point: Vector2) -> Vector2:
	if not _configured:
		return Vector2.ZERO
	return _origin() + point * _scale()


func viewport_to_image(point: Vector2) -> Vector2:
	if not _configured:
		return Vector2.ZERO
	return (point - _origin()) / _scale()


func zoom_at(viewport_point: Vector2, factor: float) -> void:
	if not _configured or not is_finite(factor) or factor <= 0.0:
		return
	var image_point := viewport_to_image(viewport_point)
	var next_zoom := clampf(user_zoom * factor, MIN_USER_ZOOM, MAX_USER_ZOOM)
	if is_equal_approx(next_zoom, user_zoom):
		return
	user_zoom = next_zoom
	pan = viewport_point - _base_origin() - image_point * _scale()


func pan_by(delta: Vector2) -> void:
	if not _configured or not delta.is_finite():
		return
	pan += delta


func _origin() -> Vector2:
	return _base_origin() + pan


func _base_origin() -> Vector2:
	return viewport_rect.position + letterbox_offset


func _scale() -> float:
	return fit_scale * user_zoom


func _valid_size(value: Vector2) -> bool:
	return value.is_finite() and value.x > 0.0 and value.y > 0.0


func _reset() -> void:
	image_size = Vector2.ZERO
	viewport_rect = Rect2()
	fit_scale = 1.0
	user_zoom = 1.0
	pan = Vector2.ZERO
	letterbox_offset = Vector2.ZERO
	_configured = false
