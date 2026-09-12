class_name EndoscapesDataset
extends RefCounted

const SPLITS := ["train", "val", "test"]
const IMAGE_EXTENSIONS := ["jpg", "jpeg", "png"]
const COCO_ADAPTER := preload(
	"res://client/plugins/source/endoscapes_video_source/endoscapes_coco_adapter.gd")


func discover(root: String, token: Variant = null) -> Dictionary:
	var normalized := ProjectSettings.globalize_path(root).simplify_path().trim_suffix("/")
	if not FileAccess.file_exists(normalized.path_join("all_metadata.csv")):
		return _discovery(false, [], PackedStringArray())
	var marker_errors := _validate_root_markers(normalized)
	if not marker_errors.is_empty():
		return _discovery(true, [], marker_errors)
	if _cancelled(token):
		return _discovery(true, [], PackedStringArray(["Endoscapes discovery cancelled"]))

	var media: Array[Dictionary] = []
	var errors := PackedStringArray()
	var found_frame_and_coco := false
	for split: String in SPLITS:
		var split_path := normalized.path_join(split)
		var directory := DirAccess.open(split_path)
		if directory == null:
			errors.append("Cannot read Endoscapes split: %s" % split)
			continue
		var summaries := {}
		for file_name: String in directory.get_files():
			if _cancelled(token):
				return _discovery(true, [], PackedStringArray([
					"Endoscapes discovery cancelled"]))
			if directory.is_link(file_name):
				continue
			var parsed := parse_frame_name(file_name)
			if parsed.is_empty():
				continue
			var video_id: int = parsed.video_id
			var summary: Dictionary = summaries.get(video_id, {
				"count": 0,
				"representative": split_path.path_join(file_name),
			})
			summary.count = int(summary.count) + 1
			if file_name < String(summary.representative).get_file():
				summary.representative = split_path.path_join(file_name)
			summaries[video_id] = summary
		var coco_path := split_path.path_join("annotation_coco.json")
		if not summaries.is_empty() and not FileAccess.file_exists(coco_path):
			errors.append("Endoscapes split is missing annotation_coco.json: %s" % split)
			continue
		if not summaries.is_empty():
			found_frame_and_coco = true
		var video_ids: Array = summaries.keys()
		video_ids.sort()
		for video_value: Variant in video_ids:
			var video_id := int(video_value)
			var summary: Dictionary = summaries[video_id]
			var logical_path := "%s/video-%03d" % [split, video_id]
			media.append({
				"display_name": "Video %03d (%d frames)" % [video_id, summary.count],
				"media_id": "endoscapes_%s_video_%03d" % [split, video_id],
				"media_type": "image_sequence",
				"source_path": String(summary.representative),
				"relative_path": logical_path,
				"label_root": normalized,
				"source_relative_path": logical_path,
				"source_plugin_id": "endoscapes_video_source",
				"baseline_kind": "imported_labels",
			})
		_report_progress(token, {
			"stage": "discover",
			"completed_split": split,
			"media_count": media.size(),
		})
	if not errors.is_empty():
		return _discovery(true, [], errors)
	if not found_frame_and_coco:
		return _discovery(true, [], PackedStringArray([
			"Endoscapes root has no split containing frames and annotation_coco.json"]))
	return _discovery(true, media, PackedStringArray())


func prepare_video(representative_frame: String, token: Variant = null) -> Dictionary:
	var context := inspect_locator(representative_frame)
	if context.is_empty():
		return _preparation_failure("Invalid Endoscapes representative frame: %s" % representative_frame)
	if _cancelled(token):
		return _preparation_failure("Endoscapes video preparation cancelled")
	var split_root: String = context.split_root
	var directory := DirAccess.open(split_root)
	if directory == null:
		return _preparation_failure("Cannot read Endoscapes split: %s" % context.split)
	var frames: Array[Dictionary] = []
	var names_by_frame := {}
	var errors := PackedStringArray()
	for file_name: String in directory.get_files():
		if _cancelled(token):
			return _preparation_failure("Endoscapes video preparation cancelled")
		if directory.is_link(file_name):
			continue
		var parsed := parse_frame_name(file_name)
		if parsed.is_empty() or int(parsed.video_id) != int(context.video_id):
			continue
		var frame_id: int = parsed.frame_id
		if names_by_frame.has(frame_id):
			errors.append("Endoscapes video %d repeats frame %d: %s and %s" % [
				context.video_id, frame_id, names_by_frame[frame_id], file_name])
			continue
		names_by_frame[frame_id] = file_name
		frames.append({"frame_id": frame_id, "file_name": file_name})
	if frames.is_empty():
		errors.append("Endoscapes video contains no readable frame paths")
	if not errors.is_empty():
		return _preparation(false, {}, [], [], context, errors)
	frames.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.frame_id) < int(right.frame_id))

	var dataset_id := "endoscapes_%s_video_%03d" % [context.split, context.video_id]
	var manifest_frames: Array[Dictionary] = []
	var frame_ids := PackedInt64Array()
	for index in range(frames.size()):
		var frame: Dictionary = frames[index]
		var frame_id := int(frame.frame_id)
		manifest_frames.append({
			"frame": index,
			"frame_id": frame_id,
			"time_s": float(frame_id),
			"image_path": String(frame.file_name),
		})
		frame_ids.append(frame_id)
	var imported := COCO_ADAPTER.new().read_for_video(
		split_root.path_join("annotation_coco.json"),
		String(context.split),
		int(context.video_id),
		frame_ids,
		token,
	)
	var import_errors: PackedStringArray = imported.get("errors", PackedStringArray([
		"Endoscapes COCO import returned no error contract"]))
	if not import_errors.is_empty():
		return _preparation(false, {}, [], [], context, import_errors)
	var records: Array = imported.get("records", [])
	var manifest := {
		"schema_version": 1,
		"dataset_id": dataset_id,
		"source_name": "Endoscapes %s video %03d" % [context.split, context.video_id],
		"source_sha256": null,
		"frame_count": manifest_frames.size(),
		"nominal_fps": 1.0,
		"frame_step": 25,
		"frames": manifest_frames,
		"model_version": "endoscapes-coco-v1",
		"taxonomy_version": "v1",
	}
	var statistics := {
		"imported_regions": int(imported.get("imported_regions", 0)),
		"polygon_regions": int(imported.get("polygon_regions", 0)),
		"box_fallbacks": int(imported.get("box_fallbacks", 0)),
		"skipped_regions": int(imported.get("skipped_regions", 0)),
		"fallback_reasons": imported.get("fallback_reasons", {}).duplicate(true),
		"skipped_reasons": imported.get("skipped_reasons", {}).duplicate(true),
	}
	var export_metadata := {
		"schema_version": 1,
		"import_bindings": imported.get("import_bindings", []).duplicate(true),
		"import_issues": imported.get("import_issues", []).duplicate(true),
	}
	return _preparation(true, manifest, manifest_frames, records, context,
		PackedStringArray(), statistics, export_metadata)


func inspect_locator(locator: String) -> Dictionary:
	var absolute := ProjectSettings.globalize_path(locator).simplify_path()
	if not FileAccess.file_exists(absolute) or _path_is_link(absolute):
		return {}
	var parsed := parse_frame_name(absolute.get_file())
	if parsed.is_empty():
		return {}
	var split_root := absolute.get_base_dir()
	var split := split_root.get_file()
	if split not in SPLITS or _path_is_link(split_root):
		return {}
	var root := split_root.get_base_dir()
	if not _validate_root_markers(root).is_empty():
		return {}
	if not FileAccess.file_exists(split_root.path_join("annotation_coco.json")):
		return {}
	return {
		"root": root,
		"split_root": split_root,
		"split": split,
		"video_id": int(parsed.video_id),
		"frame_id": int(parsed.frame_id),
		"locator": absolute,
	}


func parse_frame_name(file_name: String) -> Dictionary:
	var extension := file_name.get_extension().to_lower()
	if extension not in IMAGE_EXTENSIONS:
		return {}
	var parts := file_name.get_basename().split("_", true)
	if parts.size() != 2 or not _decimal(parts[0]) or not _decimal(parts[1]):
		return {}
	var video_id := int(parts[0])
	var frame_id := int(parts[1])
	if video_id < 0 or frame_id < 0:
		return {}
	return {"video_id": video_id, "frame_id": frame_id}


func _validate_root_markers(root: String) -> PackedStringArray:
	var errors := PackedStringArray()
	if not DirAccess.dir_exists_absolute(root) or _path_is_link(root):
		errors.append("Endoscapes root is missing or symbolic")
		return errors
	var metadata := root.path_join("all_metadata.csv")
	if not FileAccess.file_exists(metadata) or _path_is_link(metadata):
		errors.append("Endoscapes root is missing all_metadata.csv")
	for split: String in SPLITS:
		var split_path := root.path_join(split)
		if not DirAccess.dir_exists_absolute(split_path) or _path_is_link(split_path):
			errors.append("Endoscapes root is missing a safe %s split" % split)
	return errors


func _path_is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())


func _decimal(value: String) -> bool:
	if value.is_empty():
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return true


func _cancelled(token: Variant) -> bool:
	return token != null and token.has_method("is_cancelled") and bool(token.is_cancelled())


func _report_progress(token: Variant, value: Dictionary) -> void:
	if token != null and token.has_method("report_progress"):
		token.report_progress(value)


func _discovery(claimed: bool, media: Array, errors: PackedStringArray) -> Dictionary:
	return {
		"claimed": claimed,
		"media": media.duplicate(true),
		"errors": PackedStringArray(errors),
	}


func _preparation_failure(message: String) -> Dictionary:
	return _preparation(false, {}, [], [], {}, PackedStringArray([message]))


func _preparation(
	ok: bool,
	manifest: Dictionary,
	frame_entries: Array,
	records: Array,
	context: Dictionary,
	errors: PackedStringArray,
	statistics: Dictionary = {},
	export_metadata: Dictionary = {},
) -> Dictionary:
	return {
		"ok": ok,
		"manifest": manifest.duplicate(true),
		"frame_entries": frame_entries.duplicate(true),
		"records": records.duplicate(true),
		"context": context.duplicate(true),
		"statistics": statistics.duplicate(true),
		"export_metadata": export_metadata.duplicate(true),
		"errors": PackedStringArray(errors),
	}
