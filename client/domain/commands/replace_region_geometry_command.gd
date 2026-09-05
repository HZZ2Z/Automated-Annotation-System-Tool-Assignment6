class_name ReplaceRegionGeometryCommand
extends "res://client/domain/commands/replace_frame_command.gd"

const REGION_GEOMETRY := preload("res://client/domain/region_geometry.gd")

func _init(
	frame_index: int,
	old_record: Dictionary,
	region_id: String,
	requested_polygon: Variant,
	image_size: Vector2 = Vector2.ZERO,
) -> void:
	super(frame_index, old_record, old_record)
	var index := _find_region_index(after, region_id)
	if index < 0:
		_reject("region: region id %s does not exist" % region_id)
		return
	var polygon := _normalized_polygon(requested_polygon)
	if polygon.is_empty():
		_reject("replace geometry: polygon must be a simple polygon with at least three finite vertices")
		return
	var region: Dictionary = after["regions"][index]
	region.erase("box")
	region["polygon"] = polygon
	if image_size != Vector2.ZERO and not REGION_GEOMETRY.fits_image(region, image_size):
		after = before.duplicate(true)
		_reject("Geometry must stay inside the current image")


static func _normalized_polygon(value: Variant) -> Array:
	var packed := PackedVector2Array()
	if value is PackedVector2Array:
		packed = value
	elif value is Array:
		for point: Variant in value:
			if not point is Array or point.size() != 2 or not _finite_number(point[0]) or not _finite_number(point[1]):
				return []
			packed.append(Vector2(float(point[0]), float(point[1])))
	else:
		return []
	if packed.size() >= 2 and packed[0].is_equal_approx(packed[-1]):
		packed.remove_at(packed.size() - 1)
	if packed.size() < 3 or absf(_signed_area(packed)) <= 0.00001:
		return []
	if Geometry2D.triangulate_polygon(packed).is_empty():
		return []
	var result: Array = []
	for point: Vector2 in packed:
		result.append([point.x, point.y])
	return result


static func _signed_area(points: PackedVector2Array) -> float:
	var area := 0.0
	for index in range(points.size()):
		var next := (index + 1) % points.size()
		area += points[index].x * points[next].y - points[next].x * points[index].y
	return area * 0.5


static func _finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
