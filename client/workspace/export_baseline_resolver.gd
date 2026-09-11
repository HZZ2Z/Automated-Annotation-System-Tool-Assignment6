## Pure worker-side conversion of one Source-declared original-label file.
extends RefCounted

const ADAPTER := preload("res://client/workspace/cholect50_label_adapter.gd")
const DOCUMENT := preload("res://client/workspace/atomic_document.gd")
const VALIDATOR := preload("res://client/domain/model_output_validator.gd")
const DESCRIPTOR_FIELDS := {
	"kind": true,
	"path": true,
	"root": true,
	"media_id": true,
	"image_size": true,
}


func resolve(
	snapshot: Dictionary,
	descriptor: Dictionary,
	token: Variant = null
) -> Dictionary:
	var descriptor_copy := descriptor.duplicate(true)
	if _cancelled(token):
		return _failure("Baseline resolution cancelled", descriptor_copy)
	var validation := _validate_inputs(snapshot, descriptor)
	if not validation.success:
		return _failure(String(validation.error), descriptor_copy)
	var path: String = validation.path
	var document := DOCUMENT.new()
	if document._is_link(path) or document._has_link_ancestor(path.get_base_dir()):
		return _failure(
			"Original baseline path must not traverse symbolic links", descriptor_copy)
	var source_sha256 := FileAccess.get_sha256(path)
	if source_sha256.is_empty():
		return _failure("Cannot hash original baseline: %s" % path, descriptor_copy)
	var imported: Dictionary = ADAPTER.new().read(
		path,
		String(snapshot.source),
		validation.frame_ids,
		validation.image_size,
	)
	if not imported.get("errors", []).is_empty():
		return _failure(
			"Cannot convert original baseline: " + "; ".join(imported.errors),
			descriptor_copy,
			source_sha256,
		)
	if _cancelled(token):
		return _failure("Baseline resolution cancelled", descriptor_copy, source_sha256)
	if (
		document._is_link(path)
		or document._has_link_ancestor(path.get_base_dir())
		or FileAccess.get_sha256(path) != source_sha256
	):
		return _failure(
			"Original baseline changed during resolution", descriptor_copy, source_sha256)
	var indexed: Dictionary = imported.get("records", {})
	var records: Array = []
	var validator := VALIDATOR.new()
	for entry: Dictionary in snapshot.frame_entries:
		if _cancelled(token):
			return _failure("Baseline resolution cancelled", descriptor_copy, source_sha256)
		var frame_id := int(entry.frame_id)
		var record: Dictionary
		if indexed.get(frame_id) is Dictionary:
			record = indexed[frame_id].duplicate(true)
		else:
			record = {
				"schema_version": 1,
				"source": snapshot.source,
				"frame": frame_id,
				"regions": [],
			}
		record["source"] = snapshot.source
		record["frame"] = frame_id
		record.erase("time_s")
		if entry.has("time_s"):
			record["time_s"] = entry.time_s
		var record_errors: PackedStringArray = validator.validate_record(record)
		if not record_errors.is_empty():
			return _failure(
				"Invalid resolved baseline frame %d: %s" % [
					frame_id, "; ".join(record_errors)],
				descriptor_copy,
				source_sha256,
			)
		records.append(record)
	return {
		"success": true,
		"errors": [],
		"records": records,
		"source_sha256": source_sha256,
		"descriptor": descriptor_copy,
	}


func _validate_inputs(snapshot: Dictionary, descriptor: Dictionary) -> Dictionary:
	for key: Variant in descriptor:
		if typeof(key) != TYPE_STRING or not DESCRIPTOR_FIELDS.has(key):
			return {"success": false, "error": "Baseline descriptor contains an unrecognized key"}
	if descriptor.get("kind") != "cholect50":
		return {"success": false, "error": "Unsupported original baseline kind"}
	for field: String in ["path", "root", "media_id"]:
		if typeof(descriptor.get(field)) != TYPE_STRING or String(descriptor[field]).is_empty():
			return {"success": false, "error": "Baseline descriptor requires %s" % field}
	if typeof(snapshot.get("source")) != TYPE_STRING or String(snapshot.source).is_empty():
		return {"success": false, "error": "Snapshot requires a Source identity"}
	if (
		typeof(snapshot.get("media_id")) != TYPE_STRING
		or descriptor.media_id != snapshot.media_id
	):
		return {"success": false, "error": "Baseline descriptor media identity mismatch"}
	if not snapshot.get("frame_entries") is Array or snapshot.frame_entries.is_empty():
		return {"success": false, "error": "Snapshot requires complete frame entries"}
	var image_size_value: Variant = descriptor.get("image_size")
	if (
		not image_size_value is Array
		or image_size_value.size() != 2
		or not _positive_number(image_size_value[0])
		or not _positive_number(image_size_value[1])
	):
		return {"success": false, "error": "Baseline descriptor requires positive image_size"}
	var declared_root := String(descriptor.root)
	var declared_path := String(descriptor.path)
	if _has_parent_segment(declared_root) or _has_parent_segment(declared_path):
		return {"success": false, "error": "Original baseline path must remain inside its trusted root"}
	var root := ProjectSettings.globalize_path(declared_root).simplify_path().trim_suffix("/")
	var path := ProjectSettings.globalize_path(declared_path).simplify_path()
	if not DirAccess.dir_exists_absolute(root):
		return {"success": false, "error": "Original baseline root does not exist"}
	if path == root or not path.begins_with(root + "/"):
		return {"success": false, "error": "Original baseline path must remain inside its trusted root"}
	if not FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
		return {"success": false, "error": "Original baseline file does not exist"}
	var frame_ids := PackedInt64Array()
	var seen := {}
	for entry: Variant in snapshot.frame_entries:
		if not entry is Dictionary or typeof(entry.get("frame_id")) != TYPE_INT or int(entry.frame_id) < 0:
			return {"success": false, "error": "Snapshot frame entry has invalid frame identity"}
		var frame_id := int(entry.frame_id)
		if seen.has(frame_id):
			return {"success": false, "error": "Snapshot frame entries contain duplicate frame identity"}
		seen[frame_id] = true
		frame_ids.append(frame_id)
	return {
		"success": true,
		"path": path,
		"frame_ids": frame_ids,
		"image_size": Vector2(float(image_size_value[0]), float(image_size_value[1])),
	}


func _has_parent_segment(path: String) -> bool:
	for segment: String in path.replace("\\", "/").split("/", false):
		if segment == "..":
			return true
	return false


func _positive_number(value: Variant) -> bool:
	return (
		typeof(value) in [TYPE_INT, TYPE_FLOAT]
		and is_finite(float(value))
		and float(value) > 0.0
	)


func _cancelled(token: Variant) -> bool:
	return token != null and token.is_cancelled()


func _failure(
	message: String,
	descriptor: Dictionary,
	source_sha256: String = ""
) -> Dictionary:
	return {
		"success": false,
		"errors": [message],
		"records": [],
		"source_sha256": source_sha256,
		"descriptor": descriptor.duplicate(true),
	}
