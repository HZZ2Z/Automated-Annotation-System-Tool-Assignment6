class_name AddBoxCommand
extends "res://client/domain/commands/replace_frame_command.gd"


static var _next_session_id := 1

var _region_id := ""


func _init(
	frame_index: int,
	old_record: Dictionary,
	requested_box: Variant,
	class_label: Variant = "unknown",
	kind: Variant = "region",
) -> void:
	super(frame_index, old_record, old_record)
	if not requested_box is Array or requested_box.size() != 4:
		_reject("add box: geometry must be [x, y, width, height]")
		return
	if typeof(class_label) != TYPE_STRING or String(class_label).is_empty():
		_reject("add box: class must be a non-empty string")
		return
	if typeof(kind) != TYPE_STRING or String(kind).is_empty():
		_reject("add box: kind must be a non-empty string")
		return
	_region_id = _allocate_id(frame_index, after)
	var regions: Variant = after.get("regions")
	if not regions is Array:
		_reject("add box: record regions must be an array")
		return
	regions.append({
		"id": _region_id,
		"class": class_label,
		"kind": kind,
		"box": requested_box.duplicate(true),
		"track_id": null,
	})


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
		var candidate := "frame-%d-added-%d" % [frame_index, _next_session_id]
		_next_session_id += 1
		if not existing.has(candidate):
			return candidate
	return ""
