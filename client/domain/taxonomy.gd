class_name AnnotationTaxonomy
extends RefCounted

const TAXONOMY_PATH := "res://core/taxonomy/classes.json"
static var _loaded := false
static var _class_kinds: Dictionary = {}


static func kind_for_class(class_label: String) -> String:
	_ensure_loaded()
	return str(_class_kinds.get(class_label, ""))


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_class_kinds = {}
	if not FileAccess.file_exists(TAXONOMY_PATH):
		return
	var payload: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(TAXONOMY_PATH)
	)
	if not payload is Dictionary:
		return
	var classes: Variant = payload.get("classes")
	if not classes is Array:
		return
	for item: Variant in classes:
		if not item is Dictionary:
			continue
		var class_id: Variant = item.get("id")
		var kind: Variant = item.get("kind")
		if (
			typeof(class_id) == TYPE_STRING
			and not String(class_id).is_empty()
			and typeof(kind) == TYPE_STRING
			and not String(kind).is_empty()
		):
			_class_kinds[class_id] = kind
