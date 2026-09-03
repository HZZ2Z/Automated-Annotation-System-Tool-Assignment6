class_name AnnotationValidator
extends RefCounted


const TOP_LEVEL_FIELDS := {
	"schema_version": true,
	"dataset_id": true,
	"source": true,
	"frame": true,
	"time_s": true,
	"image_size": true,
	"regions": true,
}
const REQUIRED_TOP_LEVEL_FIELDS := [
	"schema_version", "dataset_id", "source", "frame", "image_size", "regions",
]
const REGION_FIELDS := {
	"id": true,
	"class": true,
	"kind": true,
	"box": true,
	"polygon": true,
	"conf": true,
	"track_id": true,
	"filled": true,
}
const REQUIRED_REGION_FIELDS := ["id", "class", "kind"]
const TAXONOMY_PATH := "res://core/taxonomy/classes.json"
const LEGAL_KINDS := ["instrument", "anatomy", "region"]

static var _taxonomy_loaded := false
static var _taxonomy_class_kinds := {}


static func taxonomy_kind_for_class(class_label: String) -> String:
	_ensure_taxonomy_loaded()
	return str(_taxonomy_class_kinds.get(class_label, ""))


static func _ensure_taxonomy_loaded() -> void:
	if _taxonomy_loaded:
		return
	_taxonomy_loaded = true
	_taxonomy_class_kinds = {}
	if not FileAccess.file_exists(TAXONOMY_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TAXONOMY_PATH))
	if not parsed is Dictionary:
		return
	var classes: Variant = parsed.get("classes")
	if not classes is Array:
		return
	for item: Variant in classes:
		if not item is Dictionary:
			continue
		var class_id: Variant = item.get("id")
		var kind: Variant = item.get("kind")
		if typeof(class_id) == TYPE_STRING and not class_id.is_empty() and typeof(kind) == TYPE_STRING and LEGAL_KINDS.has(kind):
			_taxonomy_class_kinds[class_id] = kind


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
		var schema_version: Variant = record.get("schema_version")
		if not _is_json_integer(schema_version) or int(schema_version) != 1:
			errors.append("schema_version: expected integer 1")
	if record.has("dataset_id"):
		var dataset_id: Variant = record.get("dataset_id")
		if typeof(dataset_id) != TYPE_STRING or dataset_id.is_empty():
			errors.append("dataset_id: expected non-empty string")
	if record.has("source"):
		var source: Variant = record.get("source")
		if typeof(source) != TYPE_STRING or not _is_valid_source(source):
			errors.append("source: expected model_output_vN or human_corrected")
	if record.has("frame"):
		var frame: Variant = record.get("frame")
		if not _is_json_integer(frame) or frame < 0:
			errors.append("frame: expected non-negative integer")
	if record.has("time_s"):
		var time_s: Variant = record.get("time_s")
		if not _is_finite_number(time_s) or time_s < 0:
			errors.append("time_s: expected finite non-negative number")

	var image_size: Variant = record.get("image_size")
	var bounds_are_valid := _validate_image_size(image_size, errors)
	var regions: Variant = record.get("regions")
	if not regions is Array:
		if record.has("regions"):
			errors.append("regions: expected array")
		return errors

	var seen_ids := {}
	for index in range(regions.size()):
		_validate_region(regions[index], index, image_size, bounds_are_valid, seen_ids, errors)
	return errors


func _validate_image_size(image_size: Variant, errors: PackedStringArray) -> bool:
	if not image_size is Array:
		errors.append("image_size: expected array of two positive integers")
		return false
	if image_size.size() != 2:
		errors.append("image_size: expected exactly [width, height]")
		return false
	var valid := true
	for index in range(2):
		var value: Variant = image_size[index]
		if not _is_json_integer(value) or value <= 0:
			errors.append("image_size.%d: expected positive integer" % index)
			valid = false
	return valid


func _validate_region(
	region: Variant,
	index: int,
	image_size: Variant,
	bounds_are_valid: bool,
	seen_ids: Dictionary,
	errors: PackedStringArray,
) -> void:
	var path := "regions.%d" % index
	if not region is Dictionary:
		errors.append("%s: expected object, got %s" % [path, type_string(typeof(region))])
		return

	for key: Variant in region.keys():
		if typeof(key) != TYPE_STRING or not REGION_FIELDS.has(key):
			errors.append("%s.%s: additional field is not allowed" % [path, str(key)])
	for field: String in REQUIRED_REGION_FIELDS:
		if not region.has(field):
			errors.append("%s.%s: required field missing" % [path, field])
			continue
		var value: Variant = region.get(field)
		if typeof(value) != TYPE_STRING or value.is_empty():
			errors.append("%s.%s: expected non-empty string" % [path, field])

	var class_label: Variant = region.get("class")
	var kind: Variant = region.get("kind")
	if typeof(kind) == TYPE_STRING and not LEGAL_KINDS.has(kind):
		errors.append("%s.kind: expected instrument, anatomy, or region" % path)
	if typeof(class_label) == TYPE_STRING and not class_label.is_empty() and typeof(kind) == TYPE_STRING and LEGAL_KINDS.has(kind):
		var expected_kind := taxonomy_kind_for_class(class_label)
		if not expected_kind.is_empty() and kind != expected_kind:
			errors.append("%s.kind: class %s requires kind %s" % [path, class_label, expected_kind])

	if region.has("id") and typeof(region.get("id")) == TYPE_STRING:
		var region_id: String = region.get("id")
		if seen_ids.has(region_id):
			errors.append("%s.id: duplicate region id %s" % [path, region_id])
		seen_ids[region_id] = true

	var has_box: bool = region.has("box")
	var has_polygon: bool = region.has("polygon")
	if has_box == has_polygon:
		errors.append("%s: expected exactly one of box or polygon" % path)
	if has_box:
		_validate_box(region.get("box"), path, image_size, bounds_are_valid, errors)
	if has_polygon:
		_validate_polygon(region.get("polygon"), path, image_size, bounds_are_valid, errors)

	if region.has("conf"):
		var confidence: Variant = region.get("conf")
		if not _is_finite_number(confidence) or confidence < 0 or confidence > 1:
			errors.append("%s.conf: expected finite number between 0 and 1" % path)
	if region.has("track_id"):
		var track_id: Variant = region.get("track_id")
		if track_id != null and typeof(track_id) != TYPE_STRING:
			errors.append("%s.track_id: expected string or null" % path)
	if region.has("filled") and typeof(region.get("filled")) != TYPE_BOOL:
		errors.append("%s.filled: expected boolean" % path)


func _validate_box(
	box: Variant,
	region_path: String,
	image_size: Variant,
	bounds_are_valid: bool,
	errors: PackedStringArray,
) -> void:
	var path := "%s.box" % region_path
	if not box is Array:
		errors.append("%s: expected array of four finite numbers" % path)
		return
	if box.size() != 4:
		errors.append("%s: expected exactly [x, y, width, height]" % path)
		return
	var values_are_valid := true
	for index in range(4):
		if not _is_finite_number(box[index]):
			errors.append("%s.%d: expected finite number" % [path, index])
			values_are_valid = false
	if not values_are_valid:
		return
	var x: float = box[0]
	var y: float = box[1]
	var width: float = box[2]
	var height: float = box[3]
	if x < 0:
		errors.append("%s: x must be non-negative" % path)
	if y < 0:
		errors.append("%s: y must be non-negative" % path)
	if width <= 0:
		errors.append("%s: width must be positive" % path)
	if height <= 0:
		errors.append("%s: height must be positive" % path)
	if bounds_are_valid:
		var image_width: float = image_size[0]
		var image_height: float = image_size[1]
		if x >= 0 and y >= 0 and width > 0 and height > 0 and (x + width > image_width or y + height > image_height):
			errors.append("%s: box must stay within image bounds [0, %s] x [0, %s]" % [path, str(image_width), str(image_height)])


func _validate_polygon(
	polygon: Variant,
	region_path: String,
	image_size: Variant,
	bounds_are_valid: bool,
	errors: PackedStringArray,
) -> void:
	var path := "%s.polygon" % region_path
	if not polygon is Array:
		errors.append("%s: expected array of vertices" % path)
		return
	if polygon.size() < 3:
		errors.append("%s: expected at least three vertices" % path)
	var all_vertices_are_valid: bool = polygon.size() >= 3
	for vertex_index in range(polygon.size()):
		var vertex: Variant = polygon[vertex_index]
		var vertex_path := "%s.%d" % [path, vertex_index]
		if not vertex is Array or vertex.size() != 2:
			errors.append("%s: expected exactly [x, y]" % vertex_path)
			all_vertices_are_valid = false
			continue
		if not _is_finite_number(vertex[0]) or not _is_finite_number(vertex[1]):
			errors.append("%s: expected two finite numbers" % vertex_path)
			all_vertices_are_valid = false
			continue
		if bounds_are_valid:
			var x: float = vertex[0]
			var y: float = vertex[1]
			var image_width: float = image_size[0]
			var image_height: float = image_size[1]
			if x < 0 or y < 0 or x >= image_width or y >= image_height:
				errors.append("%s: vertex must stay within image bounds [0, %s) x [0, %s)" % [vertex_path, str(image_width), str(image_height)])
	if all_vertices_are_valid:
		if _vertices_equal(polygon[0], polygon[-1]):
			errors.append("%s: first vertex must not be repeated at the end" % path)
		var distinct_count := 0
		for vertex_index in range(polygon.size()):
			var already_seen := false
			for prior_index in range(vertex_index):
				if _vertices_equal(polygon[vertex_index], polygon[prior_index]):
					already_seen = true
					break
			if not already_seen:
				distinct_count += 1
		if distinct_count < 3:
			errors.append("%s: expected at least three distinct coordinates" % path)


func _vertices_equal(left: Array, right: Array) -> bool:
	return left[0] == right[0] and left[1] == right[1]


func _is_valid_source(value: String) -> bool:
	if value == "human_corrected":
		return true
	const PREFIX := "model_output_v"
	if not value.begins_with(PREFIX):
		return false
	var version := value.substr(PREFIX.length())
	if version.is_empty() or version.unicode_at(0) < 49 or version.unicode_at(0) > 57:
		return false
	for index in range(1, version.length()):
		var code := version.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return true


func _is_json_integer(value: Variant) -> bool:
	if not _is_finite_number(value):
		return false
	return float(value) == floorf(float(value))


func _is_finite_number(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return is_finite(float(value))
