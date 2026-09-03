class_name RelabelRegionCommand
extends "res://client/domain/commands/replace_frame_command.gd"

const TAXONOMY_SCRIPT := preload("res://client/domain/taxonomy.gd")


func _init(frame_index: int, old_record: Dictionary, region_id: String, class_label: Variant) -> void:
	super(frame_index, old_record, old_record)
	var index := _find_region_index(after, region_id)
	if index < 0:
		_reject("region: region id %s does not exist" % region_id)
		return
	if typeof(class_label) != TYPE_STRING or String(class_label).is_empty():
		_reject("class: expected non-empty string")
		return
	after["regions"][index]["class"] = class_label
	var taxonomy_kind := TAXONOMY_SCRIPT.kind_for_class(String(class_label))
	if not taxonomy_kind.is_empty():
		after["regions"][index]["kind"] = taxonomy_kind
