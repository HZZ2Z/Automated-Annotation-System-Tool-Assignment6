class_name DeleteRegionCommand
extends "res://client/domain/commands/replace_frame_command.gd"


func _init(frame_index: int, old_record: Dictionary, region_id: String) -> void:
	super(frame_index, old_record, old_record)
	var index := _find_region_index(after, region_id)
	if index < 0:
		_reject("region: region id %s does not exist" % region_id)
		return
	after["regions"].remove_at(index)
