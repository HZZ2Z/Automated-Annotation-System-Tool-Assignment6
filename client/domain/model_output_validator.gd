class_name ModelOutputValidator
extends RefCounted

const TOP_LEVEL_FIELDS := {
	"schema_version": true, "source": true, "frame": true,
	"time_s": true, "regions": true,
}
const REQUIRED_TOP_LEVEL_FIELDS := ["schema_version", "source", "frame", "regions"]
const REGION_FIELDS := {
	"id": true, "class": true, "kind": true, "box": true,
	"polygon": true, "conf": true, "track_id": true,
}
const REQUIRED_REGION_FIELDS := ["id", "class", "kind"]


func validate_record(record: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not record is Dictionary:
		errors.append("$: expected object, got %s" % type_string(typeof(record)))
		return errors
	for key: Variant in record.keys():
		if typeof(key) != TYPE_STRING or not TOP_LEVEL_FIELDS.has(key):
			errors.append("%s: additional field is not allowed" % str(key))
	for field: String in REQUIRED_TOP_LEVEL_FIELDS:
		if not record.has(field):
			errors.append("%s: required field missing" % field)
	if record.has("schema_version"):
		var value: Variant = record["schema_version"]
		if not _is_json_integer(value) or int(value) != 1:
			errors.append("schema_version: expected integer 1")
	if record.has("source"):
		var value: Variant = record["source"]
		if typeof(value) != TYPE_STRING or String(value).is_empty():
			errors.append("source: expected non-empty string")
	if record.has("frame"):
		var value: Variant = record["frame"]
		if not _is_json_integer(value) or value < 0:
			errors.append("frame: expected non-negative integer")
	if record.has("time_s"):
		var value: Variant = record["time_s"]
		if not _is_finite_number(value) or value < 0:
			errors.append("time_s: expected finite non-negative number")
	var regions: Variant = record.get("regions")
	if not regions is Array:
		if record.has("regions"):
			errors.append("regions: expected array")
		return errors
	for index in range(regions.size()):
		_validate_region(regions[index], index, errors)
	return errors


func _validate_region(region: Variant, index: int, errors: PackedStringArray) -> void:
	var path := "regions.%d" % index
	if not region is Dictionary:
		errors.append("%s: expected object" % path)
		return
	for key: Variant in region.keys():
		if typeof(key) != TYPE_STRING or not REGION_FIELDS.has(key):
			errors.append("%s.%s: additional field is not allowed" % [path, str(key)])
	for field: String in REQUIRED_REGION_FIELDS:
		if not region.has(field):
			errors.append("%s.%s: required field missing" % [path, field])
		elif typeof(region[field]) != TYPE_STRING or String(region[field]).is_empty():
			errors.append("%s.%s: expected non-empty string" % [path, field])
	var has_box: bool = region.has("box")
	var has_polygon: bool = region.has("polygon")
	if not has_box and not has_polygon:
		errors.append("%s: expected box and/or polygon" % path)
	if has_box:
		_validate_box(region["box"], path, errors)
	if has_polygon:
		_validate_polygon(region["polygon"], path, errors)
	if region.has("conf"):
		var conf: Variant = region["conf"]
		if not _is_finite_number(conf) or conf < 0 or conf > 1:
			errors.append("%s.conf: expected finite number between 0 and 1" % path)
	if region.has("track_id"):
		var track_id: Variant = region["track_id"]
		if track_id != null and typeof(track_id) != TYPE_STRING:
			errors.append("%s.track_id: expected string or null" % path)


func _validate_box(box: Variant, region_path: String, errors: PackedStringArray) -> void:
	var path := "%s.box" % region_path
	if not box is Array or box.size() != 4:
		errors.append("%s: expected exactly [x, y, width, height]" % path)
		return
	for index in range(4):
		if not _is_finite_number(box[index]):
			errors.append("%s.%d: expected finite number" % [path, index])
			continue
		if index < 2 and box[index] < 0:
			errors.append("%s.%d: expected non-negative coordinate" % [path, index])
		if index >= 2 and box[index] <= 0:
			errors.append("%s.%d: expected positive extent" % [path, index])


func _validate_polygon(polygon: Variant, region_path: String, errors: PackedStringArray) -> void:
	var path := "%s.polygon" % region_path
	if not polygon is Array:
		errors.append("%s: expected array of vertices" % path)
		return
	if polygon.size() < 3:
		errors.append("%s: expected at least three vertices" % path)
	for index in range(polygon.size()):
		var vertex: Variant = polygon[index]
		var vertex_path := "%s.%d" % [path, index]
		if not vertex is Array or vertex.size() != 2:
			errors.append("%s: expected exactly [x, y]" % vertex_path)
			continue
		for coordinate in range(2):
			if not _is_finite_number(vertex[coordinate]) or vertex[coordinate] < 0:
				errors.append(
					"%s.%d: expected finite non-negative number" % [vertex_path, coordinate]
				)


func _is_json_integer(value: Variant) -> bool:
	return _is_finite_number(value) and float(value) == floorf(float(value))


func _is_finite_number(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
	)
