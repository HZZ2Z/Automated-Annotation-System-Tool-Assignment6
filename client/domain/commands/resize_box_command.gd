class_name ResizeBoxCommand
extends "res://client/domain/commands/replace_frame_command.gd"


func _init(frame_index: int, old_record: Dictionary, region_id: String, requested_box: Variant) -> void:
	super(frame_index, old_record, old_record)
	var index := _find_region_index(after, region_id)
	if index < 0:
		_reject("region: region id %s does not exist" % region_id)
		return
	var region: Dictionary = after["regions"][index]
	if not region.has("box"):
		_reject("region %s: resize is supported only for boxes" % region_id)
		return
	if not requested_box is Array or requested_box.size() != 4:
		_reject("resize: box must be [x, y, width, height]")
		return
	region["box"] = requested_box.duplicate(true)
