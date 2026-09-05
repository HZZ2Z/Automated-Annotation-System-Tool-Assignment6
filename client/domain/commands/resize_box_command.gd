class_name ResizeBoxCommand
extends "res://client/domain/commands/replace_frame_command.gd"

const REGION_GEOMETRY := preload("res://client/domain/region_geometry.gd")


func _init(
	frame_index: int,
	old_record: Dictionary,
	region_id: String,
	requested_box: Variant,
	image_size: Vector2 = Vector2.ZERO,
) -> void:
	super(frame_index, old_record, old_record)
	var index := _find_region_index(after, region_id)
	if index < 0:
		_reject("region: region id %s does not exist" % region_id)
		return
	var region: Dictionary = after["regions"][index]
	if REGION_GEOMETRY.canonical_shape(region) != REGION_GEOMETRY.SHAPE_BOX:
		_reject("region %s: resize is supported only for boxes" % region_id)
		return
	if not requested_box is Array or requested_box.size() != 4:
		_reject("resize: box must be [x, y, width, height]")
		return
	region["box"] = requested_box.duplicate(true)
	if image_size == Vector2.ZERO:
		return
	if REGION_GEOMETRY.canonical_shape(region) != REGION_GEOMETRY.SHAPE_BOX:
		after = before.duplicate(true)
		_reject("resize: box dimensions must be finite and positive")
		return
	if not REGION_GEOMETRY.fits_image(region, image_size):
		after = before.duplicate(true)
		_reject("Geometry must stay inside the current image")
