class_name AddPolygonCommand
extends "res://client/domain/commands/replace_frame_command.gd"

const REGION_GEOMETRY := preload("res://client/domain/region_geometry.gd")

static var _next_session_id := 1

var _region_id := ""


func _init(
	frame_index: int,
	old_record: Dictionary,
	requested_polygon: Variant,
	class_label: Variant = "unknown",
	kind: Variant = "region",
	image_size: Vector2 = Vector2.ZERO,
) -> void:
	super(frame_index, old_record, old_record)
	var polygon := _normalized_polygon(requested_polygon)
	if polygon.is_empty():
		_reject("add polygon: geometry must be a simple polygon with at least three finite vertices")
		return
	if typeof(class_label) != TYPE_STRING or String(class_label).is_empty():
		_reject("add polygon: class must be a non-empty string")
		return
	if typeof(kind) != TYPE_STRING or String(kind).is_empty():
		_reject("add polygon: kind must be a non-empty string")
		return
	var regions: Variant = after.get("regions")
	if not regions is Array:
		_reject("add polygon: record regions must be an array")
		return
	_region_id = _allocate_id(frame_index, after)
	var region := {
		"id": _region_id,
		"class": class_label,
		"kind": kind,
		"polygon": polygon,
		"track_id": null,
	}
	regions.append(region)
	if image_size != Vector2.ZERO and not REGION_GEOMETRY.fits_image(region, image_size):
		after = before.duplicate(true)
		_reject("Geometry must stay inside the current image")


func get_region_id() -> String:
	return _region_id


static func _allocate_id(frame_index: int, record: Dictionary) -> String:
	var existing := {}
	var regions: Variant = record.get("regions", [])
	if regions is Array:
		for value: Variant in regions:
			if value is Dictionary:
				existing[str(value.get("id", ""))] = true
	while true:
		var candidate := "frame-%d-polygon-%d" % [frame_index, _next_session_id]
		_next_session_id += 1
		if not existing.has(candidate):
			return candidate
	return ""


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
