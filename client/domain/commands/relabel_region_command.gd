class_name RelabelRegionCommand
extends "res://client/domain/commands/replace_frame_command.gd"

const TAXONOMY_SCRIPT := preload("res://client/domain/taxonomy.gd")


func _init(frame_index: int, old_record: Dictionary, region_id: String, class_label: Variant, kind: Variant = null) -> void:
	super(frame_index, old_record, old_record)
	var index := _find_region_index(after, region_id)
	if index < 0:
		_reject("region: region id %s does not exist" % region_id)
		return
	if typeof(class_label) != TYPE_STRING:
		_reject("class: expected non-empty string")
		return
	var normalized_class := String(class_label).strip_edges()
	if normalized_class.is_empty():
		_reject("class: expected non-empty string")
		return
	var normalized_kind := ""
	if kind != null:
		if typeof(kind) != TYPE_STRING:
			_reject("kind: expected non-empty string")
			return
		normalized_kind = String(kind).strip_edges()
		if normalized_kind.is_empty():
			_reject("kind: expected non-empty string")
			return
	after["regions"][index]["class"] = normalized_class
	if kind != null:
		after["regions"][index]["kind"] = normalized_kind
	else:
		var taxonomy_kind := TAXONOMY_SCRIPT.kind_for_class(normalized_class)
		if not taxonomy_kind.is_empty():
			after["regions"][index]["kind"] = taxonomy_kind
