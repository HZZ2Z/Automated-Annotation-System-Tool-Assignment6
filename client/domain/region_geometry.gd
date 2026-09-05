class_name RegionGeometry
extends RefCounted

const POLYGON_OPS := preload("res://client/domain/polygon_ops.gd")
const SHAPE_NONE := &""
const SHAPE_BOX := &"box"
const SHAPE_POLYGON := &"polygon"
const SEGMENT_EPSILON_SQUARED := 0.0000000001
const CROSS_EPSILON := 0.00001


static func canonical_shape(region: Dictionary) -> StringName:
	if polygon_points(region).size() >= 3:
		return SHAPE_POLYGON
	var box := box_rect(region)
	if box.size.x > 0.0 and box.size.y > 0.0:
		return SHAPE_BOX
	return SHAPE_NONE


static func contains(region: Dictionary, image_point: Vector2) -> bool:
	if not image_point.is_finite():
		return false
	var polygon := polygon_points(region)
	if polygon.size() >= 3:
		return _point_in_polygon(image_point, polygon)
	var box := box_rect(region)
	return (
		box.size.x > 0.0
		and box.size.y > 0.0
		and image_point.x >= box.position.x
		and image_point.y >= box.position.y
		and image_point.x <= box.end.x
		and image_point.y <= box.end.y
	)


static func image_bounds(region: Dictionary) -> Rect2:
	var polygon := polygon_points(region)
	if polygon.size() >= 3:
		var minimum := polygon[0]
		var maximum := polygon[0]
		for point: Vector2 in polygon:
			minimum.x = minf(minimum.x, point.x)
			minimum.y = minf(minimum.y, point.y)
			maximum.x = maxf(maximum.x, point.x)
			maximum.y = maxf(maximum.y, point.y)
		return Rect2(minimum, maximum - minimum)
	return box_rect(region)


static func fits_image(region: Dictionary, image_size: Vector2) -> bool:
	var polygon := polygon_points(region)
	if polygon.size() >= 3:
		return POLYGON_OPS.points_fit_image(polygon, image_size)
	var box := box_rect(region)
	if box.size.x <= 0.0 or box.size.y <= 0.0:
		return false
	return POLYGON_OPS.points_fit_image(
		PackedVector2Array([box.position, box.end]),
		image_size,
	)


static func box_rect(region: Dictionary) -> Rect2:
	var value: Variant = region.get("box")
	if not value is Array or value.size() != 4:
		return Rect2()
	for coordinate: Variant in value:
		if not _finite_number(coordinate):
			return Rect2()
	var width := float(value[2])
	var height := float(value[3])
	if width <= 0.0 or height <= 0.0:
		return Rect2()
	return Rect2(float(value[0]), float(value[1]), width, height)


static func polygon_points(region: Dictionary) -> PackedVector2Array:
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


static func _point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
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


static func _point_on_segment(point: Vector2, start: Vector2, finish: Vector2) -> bool:
	var segment := finish - start
	if segment.length_squared() <= SEGMENT_EPSILON_SQUARED:
		return point.distance_squared_to(start) <= SEGMENT_EPSILON_SQUARED
	var relative := point - start
	if absf(segment.cross(relative)) > CROSS_EPSILON:
		return false
	var projection := relative.dot(segment)
	return projection >= 0.0 and projection <= segment.length_squared()


static func _finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
