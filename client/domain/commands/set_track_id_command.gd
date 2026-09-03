class_name SetTrackIdCommand
extends "res://client/domain/commands/replace_frame_command.gd"


func _init(frame_index: int, old_record: Dictionary, region_id: String, track_id: Variant) -> void:
	super(frame_index, old_record, old_record)
	var index := _find_region_index(after, region_id)
	if index < 0:
		_reject("region: region id %s does not exist" % region_id)
		return
	if track_id != null and (typeof(track_id) != TYPE_STRING or String(track_id).is_empty()):
		_reject("track_id: expected a non-empty string or null")
		return
	after["regions"][index]["track_id"] = track_id
