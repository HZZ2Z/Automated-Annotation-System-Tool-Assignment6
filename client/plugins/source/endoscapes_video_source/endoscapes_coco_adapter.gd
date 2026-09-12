class_name EndoscapesCocoAdapter
extends RefCounted

const COCO_RLE := preload("res://client/domain/coco_rle.gd")
const IMAGE_ALGORITHMS := preload("res://client/domain/image_region_algorithms.gd")
const CLASS_KINDS := {
	"cystic_plate": "anatomy",
	"calot_triangle": "anatomy",
	"cystic_artery": "anatomy",
	"cystic_duct": "anatomy",
	"gallbladder": "anatomy",
	"tool": "instrument",
}


func read_for_video(
	coco_path: String,
	split: String,
	video_id: int,
	frame_ids: PackedInt64Array,
	token: Variant = null,
) -> Dictionary:
	if _cancelled(token):
		return _failure("Endoscapes COCO import cancelled")
	if not FileAccess.file_exists(coco_path):
		return _failure("Endoscapes COCO file does not exist: %s" % coco_path)
	var file := FileAccess.open(coco_path, FileAccess.READ)
	if file == null:
		return _failure("Cannot read Endoscapes COCO file: %s" % coco_path)
	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	if parse_error != OK:
		return _failure("Invalid Endoscapes COCO JSON at line %d: %s" % [
			parser.get_error_line(), parser.get_error_message()])
	var document: Variant = parser.data
	if not document is Dictionary:
		return _failure("Endoscapes COCO document must be an object")
	for field: String in ["images", "annotations", "categories"]:
		if not document.get(field) is Array:
			return _failure("Endoscapes COCO %s must be an array" % field)

	var errors := PackedStringArray()
	var categories := _read_categories(document.categories, errors)
	if not errors.is_empty():
		return _result([], 0, 0, 0, 0, errors)
	var requested := {}
	for frame_id: int in frame_ids:
		if frame_id < 0 or requested.has(frame_id):
			return _failure("Endoscapes frame IDs must be unique and non-negative")
		requested[frame_id] = true
	var selected_images := _read_selected_images(
		document.images, video_id, requested, errors, "detection")
	if not errors.is_empty():
		return _result([], 0, 0, 0, 0, errors)

	var source_id := "endoscapes_%s_video_%03d" % [split, video_id]
	var records: Array[Dictionary] = []
	var records_by_frame := {}
	for frame_id: int in frame_ids:
		var record := {
			"schema_version": 1,
			"source": source_id,
			"frame": frame_id,
			"time_s": float(frame_id),
			"regions": [],
		}
		records.append(record)
		records_by_frame[frame_id] = record

	var imported_regions := 0
	var polygon_regions := 0
	var box_fallbacks := 0
	var skipped_regions := 0
	var fallback_reasons := {}
	var skipped_reasons := {}
	var import_bindings: Array[Dictionary] = []
	var import_issues: Array[Dictionary] = []
	for annotation_value: Variant in document.annotations:
		if _cancelled(token):
			return _failure("Endoscapes COCO import cancelled")
		if not annotation_value is Dictionary:
			return _failure("Endoscapes COCO annotation must be an object")
		var annotation := annotation_value as Dictionary
		if not _positive_integer(annotation.get("image_id")):
			return _failure("Endoscapes COCO annotation image_id must be a positive integer")
		var image_id := int(annotation.image_id)
		if not selected_images.has(image_id):
			continue
		var image: Dictionary = selected_images[image_id]
		var source_frame_id := int(image.source_frame_id)
		if not _positive_integer(annotation.get("id")) \
				or not _positive_integer(annotation.get("category_id")):
			skipped_regions += 1
			_increment_reason(skipped_reasons, "invalid_identity")
			import_issues.append(_import_issue(
				source_frame_id, image_id, null, "", "invalid_identity", true))
			continue
		var annotation_id := int(annotation.id)
		var native_region_id := "endoscapes-%s-%d-%d" % [
			split, image_id, annotation_id]
		var category: Variant = categories.get(int(annotation.category_id))
		if not category is Dictionary:
			skipped_regions += 1
			_increment_reason(skipped_reasons, "unknown_category")
			import_issues.append(_import_issue(
				source_frame_id, image_id, annotation_id, native_region_id,
				"unknown_category", true))
			continue
		var box := _valid_box(annotation.get("bbox"), image.size)
		var region := {
			"id": native_region_id,
			"class": String(category.name),
			"kind": String(category.kind),
		}
		if not box.is_empty():
			region["box"] = box

		var segmentation_present := annotation.has("segmentation")
		var polygon: Array = []
		var fallback_reason := ""
		if segmentation_present and annotation.segmentation is Dictionary:
			var decoded := COCO_RLE.decode(annotation.segmentation)
			if not bool(decoded.get("ok", false)):
				fallback_reason = "rle_decode_failed"
			elif decoded.size != image.size:
				fallback_reason = "mask_size_mismatch"
			elif _mask_touches_image_boundary(decoded.mask, decoded.size):
				fallback_reason = "image_boundary"
			else:
				var polygonized := IMAGE_ALGORITHMS.polygonize_mask(
					decoded.mask, decoded.size)
				if bool(polygonized.get("ok", false)):
					polygon = polygonized.get("polygon", []).duplicate(true)
				else:
					fallback_reason = String(polygonized.get("code", "polygon_refused"))
		elif segmentation_present:
			fallback_reason = "unsupported_segmentation"
		if not polygon.is_empty():
			region["polygon"] = polygon
			polygon_regions += 1
		elif segmentation_present:
			if region.has("box"):
				box_fallbacks += 1
				_increment_reason(fallback_reasons,
					fallback_reason if not fallback_reason.is_empty() else "polygon_refused")
				import_issues.append(_import_issue(
					source_frame_id, image_id, annotation_id, native_region_id,
					fallback_reason if not fallback_reason.is_empty() else "polygon_refused",
					false))
			else:
				skipped_regions += 1
				_increment_reason(skipped_reasons,
					fallback_reason if not fallback_reason.is_empty() else "invalid_geometry")
				import_issues.append(_import_issue(
					source_frame_id, image_id, annotation_id, native_region_id,
					fallback_reason if not fallback_reason.is_empty() else "invalid_geometry",
					true))
				continue
		elif not region.has("box"):
			skipped_regions += 1
			_increment_reason(skipped_reasons, "invalid_geometry")
			import_issues.append(_import_issue(
				source_frame_id, image_id, annotation_id, native_region_id,
				"invalid_geometry", true))
			continue
		var target_record: Dictionary = records_by_frame[int(image.frame_id)]
		target_record.regions.append(region)
		import_bindings.append({
			"source_frame_id": source_frame_id,
			"image_id": image_id,
			"original_annotation_id": annotation_id,
			"native_region_id": native_region_id,
			"imported_region": region.duplicate(true),
			"fallback_reason": fallback_reason if not fallback_reason.is_empty() else null,
		})
		imported_regions += 1

	for record: Dictionary in records:
		record.regions.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
			return String(left.id) < String(right.id))
	import_bindings.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if int(left.source_frame_id) != int(right.source_frame_id):
			return int(left.source_frame_id) < int(right.source_frame_id)
		return int(left.original_annotation_id) < int(right.original_annotation_id))
	import_issues.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if int(left.source_frame_id) != int(right.source_frame_id):
			return int(left.source_frame_id) < int(right.source_frame_id)
		var left_id := int(left.original_annotation_id) if left.original_annotation_id != null else -1
		var right_id := int(right.original_annotation_id) if right.original_annotation_id != null else -1
		if left_id != right_id: return left_id < right_id
		return String(left.code) < String(right.code))
	return _result(records, imported_regions, polygon_regions, box_fallbacks,
		skipped_regions, PackedStringArray(), fallback_reasons, skipped_reasons,
		import_bindings, import_issues)


func _increment_reason(counts: Dictionary, reason: String) -> void:
	counts[reason] = int(counts.get(reason, 0)) + 1


func _import_issue(
	source_frame_id: int,
	image_id: int,
	original_annotation_id: Variant,
	native_region_id: String,
	code: String,
	blocking: bool,
) -> Dictionary:
	return {
		"source_frame_id": source_frame_id,
		"image_id": image_id,
		"original_annotation_id": original_annotation_id,
		"native_region_id": native_region_id,
		"code": code,
		"blocking": blocking,
	}


func _read_categories(values: Array, errors: PackedStringArray) -> Dictionary:
	var result := {}
	for value: Variant in values:
		if not value is Dictionary:
			errors.append("Endoscapes COCO category must be an object")
			continue
		if not _positive_integer(value.get("id")) or typeof(value.get("name")) != TYPE_STRING:
			errors.append("Endoscapes COCO category requires positive integer id and string name")
			continue
		var category_id := int(value.id)
		var category_name := String(value.name)
		if result.has(category_id):
			errors.append("Endoscapes COCO repeats category id %d" % category_id)
			continue
		if CLASS_KINDS.has(category_name):
			result[category_id] = {
				"name": category_name,
				"kind": CLASS_KINDS[category_name],
			}
	return result


func _read_selected_images(
	values: Array,
	video_id: int,
	requested: Dictionary,
	errors: PackedStringArray,
	view_role: String = "detection",
) -> Dictionary:
	var result := {}
	var selected_frames := {}
	if view_role not in ["detection", "video", "ds"]:
		errors.append("Endoscapes COCO image view role is invalid")
		return result
	for value: Variant in values:
		if not value is Dictionary:
			errors.append("Endoscapes COCO image must be an object")
			continue
		if not _positive_integer(value.get("id")) or typeof(value.get("file_name")) != TYPE_STRING:
			errors.append("Endoscapes COCO image requires positive integer id and string file_name")
			continue
		var parsed := _parse_frame_name(String(value.file_name))
		if parsed.is_empty():
			errors.append("Endoscapes COCO image has invalid file_name: %s" % value.file_name)
			continue
		var declared_video: Variant = value.get("video_id")
		if declared_video != null and not _nonnegative_integer(declared_video):
			errors.append("Endoscapes COCO image video_id must be non-negative integer or null")
			continue
		var image_video_id := int(declared_video) if declared_video != null else int(parsed.video_id)
		if image_video_id != int(parsed.video_id):
			errors.append("Endoscapes COCO image video_id disagrees with file_name")
			continue
		var declared_frame: Variant = value.get("frame_id")
		if declared_frame != null and not _nonnegative_integer(declared_frame):
			errors.append("Endoscapes COCO image frame_id must be non-negative integer or null")
			continue
		var source_frame_id := int(parsed.frame_id)
		var dataset_sequence_index: Variant = (
			int(declared_frame)
			if view_role == "video" and declared_frame != null
			else null)
		if (
			view_role != "video"
			and declared_frame != null
			and int(declared_frame) != source_frame_id
		):
			errors.append("Endoscapes COCO image frame_id disagrees with file_name")
			continue
		if not _integer(value.get("width")) or not _integer(value.get("height")):
			errors.append("Endoscapes COCO image dimensions must be integers")
			continue
		var size := Vector2i(int(value.width), int(value.height))
		if size.x <= 0 or size.y <= 0:
			errors.append("Endoscapes COCO image dimensions must be positive")
			continue
		if image_video_id != video_id or not requested.has(source_frame_id):
			continue
		var image_id := int(value.id)
		if result.has(image_id):
			errors.append("Endoscapes COCO repeats image id %d" % image_id)
			continue
		if selected_frames.has(source_frame_id):
			errors.append("Endoscapes COCO repeats source frame %d" % source_frame_id)
			continue
		selected_frames[source_frame_id] = image_id
		result[image_id] = {
			"frame_id": source_frame_id,
			"source_frame_id": source_frame_id,
			"dataset_sequence_index": dataset_sequence_index,
			"file_name": String(value.file_name),
			"size": size,
		}
	return result


func _valid_box(value: Variant, image_size: Vector2i) -> Array:
	if not value is Array or value.size() != 4:
		return []
	for coordinate: Variant in value:
		if not _number(coordinate):
			return []
	var x := float(value[0])
	var y := float(value[1])
	var width := float(value[2])
	var height := float(value[3])
	if (
		x < 0.0 or y < 0.0 or width <= 0.0 or height <= 0.0
		or x + width > image_size.x or y + height > image_size.y
	):
		return []
	return [x, y, width, height]


func _mask_touches_image_boundary(mask: PackedByteArray, size: Vector2i) -> bool:
	for x in range(size.x):
		if mask[x] != 0 or mask[(size.y - 1) * size.x + x] != 0:
			return true
	for y in range(1, size.y - 1):
		if mask[y * size.x] != 0 or mask[y * size.x + size.x - 1] != 0:
			return true
	return false


func _parse_frame_name(file_name: String) -> Dictionary:
	var extension := file_name.get_extension().to_lower()
	if extension not in ["jpg", "jpeg", "png"]:
		return {}
	var parts := file_name.get_basename().split("_", true)
	if parts.size() != 2 or not _decimal(parts[0]) or not _decimal(parts[1]):
		return {}
	return {"video_id": int(parts[0]), "frame_id": int(parts[1])}


func _decimal(value: String) -> bool:
	if value.is_empty():
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return true


func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floorf(float(value))


func _nonnegative_integer(value: Variant) -> bool:
	return _integer(value) and float(value) >= 0.0


func _positive_integer(value: Variant) -> bool:
	return _integer(value) and float(value) >= 1.0


func _number(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
	)


func _cancelled(token: Variant) -> bool:
	return token != null and token.has_method("is_cancelled") and bool(token.is_cancelled())


func _failure(message: String) -> Dictionary:
	return _result([], 0, 0, 0, 0, PackedStringArray([message]))


func _result(
	records: Array,
	imported_regions: int,
	polygon_regions: int,
	box_fallbacks: int,
	skipped_regions: int,
	errors: PackedStringArray,
	fallback_reasons: Dictionary = {},
	skipped_reasons: Dictionary = {},
	import_bindings: Array = [],
	import_issues: Array = [],
) -> Dictionary:
	return {
		"records": records.duplicate(true),
		"imported_regions": imported_regions,
		"polygon_regions": polygon_regions,
		"box_fallbacks": box_fallbacks,
		"skipped_regions": skipped_regions,
		"fallback_reasons": fallback_reasons.duplicate(true),
		"skipped_reasons": skipped_reasons.duplicate(true),
		"import_bindings": import_bindings.duplicate(true),
		"import_issues": import_issues.duplicate(true),
		"errors": PackedStringArray(errors),
	}
