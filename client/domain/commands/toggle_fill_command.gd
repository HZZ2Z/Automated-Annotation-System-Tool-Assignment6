class_name ToggleFillCommand
extends "res://client/domain/commands/replace_frame_command.gd"


func _init(frame_index: int, old_record: Dictionary, region_id: String, requested_fill: Variant = null) -> void:
	super(frame_index, old_record, old_record)
	var index := _find_region_index(after, region_id)
	if index < 0:
		_reject("region: region id %s does not exist" % region_id)
		return
	if requested_fill != null and typeof(requested_fill) != TYPE_BOOL:
		_reject("filled: expected boolean")
		return
	var region: Dictionary = after["regions"][index]
	region["filled"] = not bool(region.get("filled", true)) if requested_fill == null else requested_fill
