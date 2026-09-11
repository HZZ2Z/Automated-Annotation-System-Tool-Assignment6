## Source-specific preparation on a worker. No textures or active scene objects.
extends RefCounted

const LABEL := preload("res://client/workspace/media_label_store.gd")
const REPOSITORY := preload("res://client/workspace/session_repository.gd")
const PATHS := preload("res://client/workspace/workspace_paths.gd")
const IMPORTED_LABELS := preload("res://client/workspace/cholect50_label_adapter.gd")

func open_workspace(options: Dictionary, token: Variant) -> Dictionary:
	var media: Dictionary = options.media
	var baseline_kind_value: Variant = media.get(
		"baseline_kind",
		"model" if options.manifest.get("model_version", "none") != "none" else "empty",
	)
	if (
		typeof(baseline_kind_value) != TYPE_STRING
		or String(baseline_kind_value) not in ["empty", "model", "imported_labels"]
	):
		return {"success":false,"errors":["Workspace baseline_kind is invalid"]}
	var requested_baseline_kind := String(baseline_kind_value)
	var label_root := String(media.get("label_root",options.root))
	var entries: Array = options.frame_entries
	var records: Array = []
	var kind := "empty"
	var descriptor := {}
	var imported_path := label_root.path_join("labels/%s.json" % media.media_id)
	if FileAccess.file_exists(imported_path):
		descriptor = {
			"kind": "cholect50",
			"path": imported_path,
			"root": label_root,
			"media_id": media.media_id,
			"image_size": [options.image_size.x, options.image_size.y],
		}
	if not FileAccess.file_exists(PATHS.label_path(label_root, media.media_id)):
		if FileAccess.file_exists(imported_path):
			var ids := PackedInt64Array()
			for entry: Dictionary in entries: ids.append(int(entry.frame_id))
			var imported: Dictionary = IMPORTED_LABELS.new().read(imported_path,media.media_id,ids,options.image_size)
			if not imported.errors.is_empty(): return {"success":false,"errors":imported.errors}
			records.assign(imported.records.values() if imported.records is Dictionary else imported.records)
			kind = "imported_labels"
		elif requested_baseline_kind in ["model", "imported_labels"]:
			records = options.records.duplicate(true)
			kind = requested_baseline_kind
			for record: Dictionary in records: record.source = media.media_id
	if token.is_cancelled(): return {"success":false,"errors":["Opening cancelled"],"cancelled":true}
	var label = LABEL.new()
	var context := {"baseline_kind":kind,"model_revision":options.manifest.get("model_revision",options.manifest.get("model_version","none")),"taxonomy_version":options.taxonomy_version,"source_root":label_root}
	var errors: PackedStringArray = label.prepare(options.root,media,entries,records,context)
	if not errors.is_empty(): return {"success":false,"errors":errors}
	label.set_baseline_descriptor(descriptor)
	if token.is_cancelled(): return {"success":false,"errors":["Opening cancelled"],"cancelled":true}
	return {"success":true,"errors":[],"label_store":label,"store":label.prepared_store()}

func open_direct(options: Dictionary, token: Variant) -> Dictionary:
	var records: Array = options.records
	if records.is_empty(): return {"success":false,"errors":["Source has no frame records"]}
	var locator := String(options.locator)
	var media_id := PATHS.portable_media_id(String(options.manifest.get("dataset_id",locator.get_file())))
	var path := String(options.session_root).path_join(locator.sha256_text()).path_join("label/%s.json" % media_id)
	var has_model: bool = options.manifest.get("model_version","none") != "none"
	var request := {"path":path,"media_id":media_id,"media_type":"image" if records.size() == 1 else "image_sequence","source":records[0].source,"source_relative_path":media_id,"source_sha256":options.manifest.get("source_sha256"),"source_root":locator,"frame_entries":options.frame_entries,"seed_records":records if has_model else [],"baseline_kind":"model" if has_model else "empty","model_revision":options.manifest.get("model_revision",options.manifest.get("model_version","none")),"taxonomy_version":options.taxonomy_version}
	var result: Dictionary = REPOSITORY.new().open_session(request,token)
	if not result.success: return result
	if token.is_cancelled(): return {"success":false,"errors":["Opening cancelled"],"cancelled":true}
	var label = LABEL.new()
	label.adopt_session(result)
	return {"success":true,"errors":[],"label_store":label,"store":result.store}
