class_name CholecT50LabelAdapter
extends RefCounted


const VALIDATOR_SCRIPT := preload("res://client/domain/model_output_validator.gd")


var _validator = VALIDATOR_SCRIPT.new()


func can_read(value: Variant) -> bool:
	return (
		value is Dictionary
		and value.get("annotations") is Dictionary
		and value.get("categories") is Dictionary
		and value.get("categories", {}).get("instrument") is Dictionary
		and _is_positive_number(value.get("fps"))
	)


func read(
	path: String,
	media_id_value: String,
	frame_ids: PackedInt64Array,
	image_size: Vector2
) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {
			"records": {},
			"errors": PackedStringArray(["Cannot read CholecT50 label: %s" % path]),
		}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		return {
			"records": {},
			"errors": PackedStringArray([
				"CholecT50 label is malformed: %s (line %d)" % [
					path, parser.get_error_line()]]),
		}
	return convert_label(parser.data, media_id_value, frame_ids, image_size)


func convert_label(
	value: Variant,
	media_id_value: String,
	frame_ids: PackedInt64Array,
	image_size: Vector2
) -> Dictionary:
	var errors := PackedStringArray()
	var records := {}
	if not can_read(value):
		return {
			"records": records,
			"errors": PackedStringArray(["Value is not a compatible CholecT50 label"]),
		}
	if image_size.x <= 0.0 or image_size.y <= 0.0:
		return {
			"records": records,
			"errors": PackedStringArray(["CholecT50 conversion requires positive image dimensions"]),
		}
	var allowed := {}
	for frame_id: int in frame_ids:
		allowed[frame_id] = true
	var fps := float(value["fps"])
	var annotations := value["annotations"] as Dictionary
	var instruments := value["categories"]["instrument"] as Dictionary
	var keys := Array(annotations.keys())
	keys.sort_custom(func(left: Variant, right: Variant) -> bool: return int(left) < int(right))
	for key_value: Variant in keys:
		var key := String(key_value)
		if not _is_decimal(key) or str(int(key)) != key:
			errors.append("annotations.%s: expected unpadded decimal frame key" % key)
			continue
		var frame_id := int(key)
		if not allowed.has(frame_id):
			continue
		var rows: Variant = annotations[key]
		if not rows is Array:
			errors.append("annotations.%s: expected an Array" % key)
			continue
		var regions: Array[Dictionary] = []
		for row_index in range(rows.size()):
			var row: Variant = rows[row_index]
			if not row is Array or row.size() < 8:
				errors.append("annotations.%s.%d: expected a CholecT50 row" % [
					key, row_index])
				continue
			var geometry_error := _geometry_error(row)
			if not geometry_error.is_empty():
				errors.append("annotations.%s.%d: %s" % [
					key, row_index, geometry_error])
				continue
			var instrument_key := str(int(row[1]))
			var instrument_name: Variant = instruments.get(instrument_key)
			if typeof(instrument_name) != TYPE_STRING or instrument_name.is_empty():
				errors.append("annotations.%s.%d: unknown instrument %s" % [
					key, row_index, instrument_key])
				continue
			regions.append({
				"id": "cholect50-%d-%d" % [frame_id, row_index],
				"class": instrument_name,
				"kind": "instrument",
				"box": [
					float(row[3]) * image_size.x,
					float(row[4]) * image_size.y,
					float(row[5]) * image_size.x,
					float(row[6]) * image_size.y,
				],
				"conf": 1.0,
				"track_id": null,
			})
		var record := {
			"schema_version": 1,
			"source": media_id_value,
			"frame": frame_id,
			"time_s": float(frame_id) / fps,
			"regions": regions,
		}
		var record_errors: PackedStringArray = _validator.validate_record(record)
		for error: String in record_errors:
			errors.append("annotations.%s.%s" % [key, error])
		if record_errors.is_empty():
			records[frame_id] = record
	return {"records": records, "errors": errors}


func _geometry_error(row: Array) -> String:
	for index in range(3, 7):
		if not _is_finite_number(row[index]):
			return "normalized box values must be finite numbers"
	if float(row[3]) < 0.0 or float(row[4]) < 0.0:
		return "normalized box origin must be non-negative"
	if float(row[5]) <= 0.0 or float(row[6]) <= 0.0:
		return "normalized box size must be positive"
	return ""


func _is_positive_number(value: Variant) -> bool:
	return _is_finite_number(value) and float(value) > 0.0


func _is_finite_number(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
	)


func _is_decimal(value: String) -> bool:
	if value.is_empty():
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return true
