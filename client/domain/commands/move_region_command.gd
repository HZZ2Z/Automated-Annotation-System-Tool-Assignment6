class_name MoveRegionCommand
extends "res://client/domain/commands/replace_frame_command.gd"


func _init(frame_index: int, old_record: Dictionary, region_id: String, delta: Vector2) -> void:
	super(frame_index, old_record, old_record)
	var index := _find_region_index(after, region_id)
	if index < 0:
		_reject("region: region id %s does not exist" % region_id)
		return
	if not delta.is_finite():
		_reject("move: delta must contain finite image coordinates")
		return
	var region: Dictionary = after["regions"][index]
	if region.has("box"):
		var box: Variant = region.get("box")
		if not box is Array or box.size() != 4:
			_reject("region %s: box must be [x, y, width, height]" % region_id)
			return
		var moved: Array = box.duplicate(true)
		moved[0] = float(moved[0]) + delta.x
		moved[1] = float(moved[1]) + delta.y
		region["box"] = moved
		return
	var polygon: Variant = region.get("polygon")
	if not polygon is Array:
		_reject("region %s: move requires box or polygon geometry" % region_id)
		return
	var moved_polygon: Array = []
	for point: Variant in polygon:
		if not point is Array or point.size() != 2:
			_reject("region %s: polygon vertex must be [x, y]" % region_id)
			return
		moved_polygon.append([float(point[0]) + delta.x, float(point[1]) + delta.y])
	region["polygon"] = moved_polygon
