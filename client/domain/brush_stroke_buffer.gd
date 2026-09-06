class_name BrushStrokeBuffer
extends RefCounted

const MAX_MASK_PIXELS := 1048576
const RASTER_PADDING := 2

var _active := false
var _radius := 0.0
var _image_size := Vector2i.ZERO
var _has_point := false
var _last_point := Vector2.ZERO
var _minimum := Vector2.ZERO
var _maximum := Vector2.ZERO
var _roi := Rect2i()
var _storage_roi := Rect2i()
var _mask := PackedByteArray()


func begin(radius: float, image_size: Vector2i) -> PackedStringArray:
	if not is_finite(radius) or radius <= 0.0:
		return PackedStringArray(["Brush radius must be finite and positive."])
	if image_size.x <= 0 or image_size.y <= 0:
		return PackedStringArray(["Image size must be positive."])
	reset()
	_radius = radius
	_image_size = image_size
	_active = true
	return PackedStringArray()


func append_point(point: Vector2) -> PackedStringArray:
	if not _active:
		return PackedStringArray(["Begin a brush stroke before appending points."])
	if not point.is_finite():
		return PackedStringArray(["A brush sample must be finite."])
	var next_minimum := _minimum.min(point) if _has_point else point
	var next_maximum := _maximum.max(point) if _has_point else point
	var next_roi := _bounds(next_minimum, next_maximum)
	if next_roi.size.x * next_roi.size.y > MAX_MASK_PIXELS:
		return PackedStringArray(["Mask ROI exceeds the 1,048,576 pixel safety limit."])
	var start := _last_point if _has_point else point
	# 所有可拒绝的检查先完成，失败不改变端点、像素或容量。
	_grow_storage(next_roi)
	var segment_roi := _bounds(start.min(point), start.max(point))
	_rasterize_segment(start, point, segment_roi)
	_roi = next_roi
	_minimum = next_minimum
	_maximum = next_maximum
	_last_point = point
	_has_point = true
	return PackedStringArray()


func snapshot() -> Dictionary:
	return {"roi": _roi, "mask": _copy_into(_roi)}


func reset() -> void:
	_active = false
	_radius = 0.0
	_image_size = Vector2i.ZERO
	_has_point = false
	_last_point = Vector2.ZERO
	_minimum = Vector2.ZERO
	_maximum = Vector2.ZERO
	_roi = Rect2i()
	_storage_roi = Rect2i()
	_mask = PackedByteArray()


func _bounds(minimum: Vector2, maximum: Vector2) -> Rect2i:
	# 先以浮点数裁剪，避免图像外大坐标转换为 Vector2i 时溢出。
	var reach := ceilf(_radius) + RASTER_PADDING
	var left := int(clampf(floor(minimum.x) - reach, 0.0, _image_size.x))
	var top := int(clampf(floor(minimum.y) - reach, 0.0, _image_size.y))
	var right := int(clampf(ceil(maximum.x) + reach, 0.0, _image_size.x))
	var bottom := int(clampf(ceil(maximum.y) + reach, 0.0, _image_size.y))
	if right <= left or bottom <= top:
		return Rect2i()
	return Rect2i(left, top, right - left, bottom - top)


func _grow_storage(required: Rect2i) -> void:
	if required == Rect2i() or _storage_roi.encloses(required):
		return
	var width := mini(_image_size.x, maxi(required.size.x, _storage_roi.size.x * 2))
	var height := mini(_image_size.y, maxi(required.size.y, _storage_roi.size.y * 2))
	# 接近上限时只保留能容纳的余量，不因预留空间拒绝合法笔迹。
	if width * height > MAX_MASK_PIXELS:
		height = required.size.y
		width = mini(width, MAX_MASK_PIXELS / height)
	if width * height > MAX_MASK_PIXELS or width < required.size.x:
		width = required.size.x
		height = required.size.y
	var left := clampi(required.position.x - (width - required.size.x) / 2, 0, _image_size.x - width)
	var top := clampi(required.position.y - (height - required.size.y) / 2, 0, _image_size.y - height)
	var grown := Rect2i(left, top, width, height)
	_mask = _copy_into(grown)
	_storage_roi = grown


func _copy_into(target: Rect2i) -> PackedByteArray:
	var output := PackedByteArray()
	if target == Rect2i():
		return output
	var overlap := target.intersection(_roi)
	if not overlap.has_area():
		output.resize(target.size.x * target.size.y)
		return output
	output.resize((overlap.position.y - target.position.y) * target.size.x)
	var left_padding := PackedByteArray()
	left_padding.resize(overlap.position.x - target.position.x)
	var right_padding := PackedByteArray()
	right_padding.resize(target.end.x - overlap.end.x)
	for y in range(overlap.position.y, overlap.end.y):
		output.append_array(left_padding)
		var source_index := (y - _storage_roi.position.y) * _storage_roi.size.x + overlap.position.x - _storage_roi.position.x
		output.append_array(_mask.slice(source_index, source_index + overlap.size.x))
		output.append_array(right_padding)
	output.resize(target.size.x * target.size.y)
	return output


func _rasterize_segment(start: Vector2, finish: Vector2, bounds: Rect2i) -> void:
	var segment := finish - start
	var length_squared := segment.length_squared()
	var radius_squared := _radius * _radius
	for y in range(bounds.position.y, bounds.end.y):
		var row_offset := (y - _storage_roi.position.y) * _storage_roi.size.x - _storage_roi.position.x
		for x in range(bounds.position.x, bounds.end.x):
			var index := row_offset + x
			if _mask[index] != 0:
				continue
			var center := Vector2(x + 0.5, y + 0.5)
			var distance_squared := INF
			if length_squared <= 0.000000001:
				distance_squared = center.distance_squared_to(start)
			elif is_finite(length_squared):
				var progress := clampf((center - start).dot(segment) / length_squared, 0.0, 1.0)
				distance_squared = center.distance_squared_to(start + progress * segment)
			if not is_finite(distance_squared):
				# 极远图像外端点使用双精度标量，避免 Vector2 平方溢出。
				var dx := float(finish.x) - float(start.x)
				var dy := float(finish.y) - float(start.y)
				var px := float(center.x) - float(start.x)
				var py := float(center.y) - float(start.y)
				var scalar_length_squared := dx * dx + dy * dy
				var progress := 0.0
				if scalar_length_squared > 0.000000001:
					progress = clampf((px * dx + py * dy) / scalar_length_squared, 0.0, 1.0)
				distance_squared = pow(px - progress * dx, 2) + pow(py - progress * dy, 2)
			if distance_squared <= radius_squared:
				_mask[index] = 1
