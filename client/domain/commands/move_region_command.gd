class_name MoveRegionCommand
extends "res://client/domain/commands/replace_frame_command.gd"

const REGION_GEOMETRY := preload("res://client/domain/region_geometry.gd")


func _init(
	frame_index: int,
	old_record: Dictionary,
	region_id: String,
	delta: Vector2,
	image_size: Vector2 = Vector2.ZERO,
) -> void:
	super(frame_index, old_record, old_record)
	var index := _find_region_index(after, region_id)
	if index < 0:
		_reject("region: region id %s does not exist" % region_id)
		return
	if not delta.is_finite():
		_reject("move: delta must contain finite image coordinates")
		return
	var region: Dictionary = after["regions"][index]
	var shape: StringName = REGION_GEOMETRY.canonical_shape(region)
	if shape == REGION_GEOMETRY.SHAPE_POLYGON:
		var polygon: Variant = region.get("polygon")
		var moved_polygon: Array = []
		for point: Variant in polygon:
			moved_polygon.append([float(point[0]) + delta.x, float(point[1]) + delta.y])
		region["polygon"] = moved_polygon
		_validate_image_bounds(region, image_size)
		return
	if shape == REGION_GEOMETRY.SHAPE_BOX:
		var box: Variant = region.get("box")
		var moved: Array = box.duplicate(true)
		moved[0] = float(moved[0]) + delta.x
		moved[1] = float(moved[1]) + delta.y
		region["box"] = moved
		_validate_image_bounds(region, image_size)
		return
	_reject("region %s: move requires valid box or polygon geometry" % region_id)


func _validate_image_bounds(region: Dictionary, image_size: Vector2) -> void:
	if image_size != Vector2.ZERO and not REGION_GEOMETRY.fits_image(region, image_size):
		after = before.duplicate(true)
		_reject("Geometry must stay inside the current image")
