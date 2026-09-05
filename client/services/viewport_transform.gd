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
var _image_to_viewport_transform := Transform2D.IDENTITY
var _viewport_to_image_transform := Transform2D.IDENTITY


func configure(new_image_size: Vector2, new_viewport_rect: Rect2) -> bool:
	var dimensions_are_valid := _valid_size(new_image_size) and _valid_size(new_viewport_rect.size)
	var preserve_user_view := dimensions_are_valid and _configured and image_size.is_equal_approx(new_image_size)
	var preserved_zoom := user_zoom
	var preserved_image_center := viewport_to_image(viewport_rect.get_center()) if preserve_user_view else Vector2.ZERO
	_reset()
	if not dimensions_are_valid:
		return false
	image_size = new_image_size
	viewport_rect = new_viewport_rect
	fit_scale = minf(viewport_rect.size.x / image_size.x, viewport_rect.size.y / image_size.y)
	if not is_finite(fit_scale) or fit_scale <= 0.0:
		_reset()
		return false
	letterbox_offset = (viewport_rect.size - image_size * fit_scale) * 0.5
	if preserve_user_view:
		user_zoom = preserved_zoom
		pan = viewport_rect.get_center() - _base_origin() - preserved_image_center * _scale()
	_configured = true
	_update_matrices()
	return true


func is_configured() -> bool:
	return _configured


func image_to_viewport(point: Vector2) -> Vector2:
	if not _configured:
		return Vector2.ZERO
	return _image_to_viewport_transform * point


func viewport_to_image(point: Vector2) -> Vector2:
	if not _configured:
		return Vector2.ZERO
	return _viewport_to_image_transform * point


func get_image_to_viewport_transform() -> Transform2D:
	return _image_to_viewport_transform


func get_viewport_to_image_transform() -> Transform2D:
	return _viewport_to_image_transform


func contains_viewport_point(point: Vector2) -> bool:
	if not _configured or not point.is_finite():
		return false
	var image_point := viewport_to_image(point)
	return (
		image_point.x >= 0.0
		and image_point.y >= 0.0
		and image_point.x <= image_size.x
		and image_point.y <= image_size.y
	)


func reset_to_fit() -> bool:
	if not _configured or (is_equal_approx(user_zoom, 1.0) and pan.is_zero_approx()):
		return false
	user_zoom = 1.0
	pan = Vector2.ZERO
	_update_matrices()
	return true


func zoom_at(viewport_point: Vector2, factor: float) -> void:
	if not _configured or not is_finite(factor) or factor <= 0.0:
		return
	var image_point := viewport_to_image(viewport_point)
	var next_zoom := clampf(user_zoom * factor, MIN_USER_ZOOM, MAX_USER_ZOOM)
	if is_equal_approx(next_zoom, user_zoom):
		return
	user_zoom = next_zoom
	pan = viewport_point - _base_origin() - image_point * _scale()
	_update_matrices()


func pan_by(delta: Vector2) -> void:
	if not _configured or not delta.is_finite():
		return
	pan += delta
	_update_matrices()


func _origin() -> Vector2:
	return _base_origin() + pan


func _base_origin() -> Vector2:
	return viewport_rect.position + letterbox_offset


func _scale() -> float:
	return fit_scale * user_zoom


func _update_matrices() -> void:
	var scale := _scale()
	_image_to_viewport_transform = Transform2D(
		Vector2(scale, 0.0),
		Vector2(0.0, scale),
		_origin(),
	)
	_viewport_to_image_transform = _image_to_viewport_transform.affine_inverse()


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
	_image_to_viewport_transform = Transform2D.IDENTITY
	_viewport_to_image_transform = Transform2D.IDENTITY
