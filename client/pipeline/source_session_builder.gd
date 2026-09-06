class_name SourceSessionBuilder
extends RefCounted


func build(source: Variant, include_presentation: bool) -> Dictionary:
	var errors := PackedStringArray()
	var frame_count_value: Variant = source.get_frame_count()
	if not _positive_integer(frame_count_value):
		errors.append("Source frame count must be a positive integer")
	var frame_count := (
		int(frame_count_value) if _positive_integer(frame_count_value) else 0)

	var manifest_value: Variant = source.get_manifest()
	var manifest: Dictionary = (
		manifest_value.duplicate(true) if manifest_value is Dictionary else {})
	if manifest.is_empty():
		errors.append("Source manifest must be a non-empty Dictionary")
	if not _positive_integer(manifest.get("frame_count")):
		errors.append("Source manifest frame_count must be a positive integer")
	elif int(manifest["frame_count"]) != frame_count:
		errors.append(
			"Source manifest frame_count must match the source frame count")
	if not _positive_number(manifest.get("nominal_fps")):
		errors.append("Source manifest nominal_fps must be finite and positive")

	var records_value: Variant = source.get_model_records()
	var records: Array = []
	if not records_value is Array:
		errors.append("Source model records must be an Array")
	elif records_value.size() != frame_count:
		errors.append(
			"Source model records must contain exactly one record per frame")
	else:
		for value: Variant in records_value:
			records.append(
				value.duplicate(true) if value is Dictionary else value)

	var entries: Array[Dictionary] = []
	var playback: Array[Dictionary] = []
	var seen_ids := {}
	var previous_time := -1.0
	for index in range(frame_count):
		var entry_value: Variant = source.get_frame_entry(index)
		if not entry_value is Dictionary:
			errors.append("Source frame %d entry must be a Dictionary" % index)
			continue
		var entry := (entry_value as Dictionary).duplicate(true)
		var playback_frame: Variant = entry.get("frame")
		var time_value: Variant = entry.get("time_s")
		var frame_id_value: Variant = entry.get("frame_id", playback_frame)
		if not _integer(playback_frame) or int(playback_frame) != index:
			errors.append(
				"Source frame entries must contain playback frame %d" % index)
			continue
		if not _non_negative_number(time_value):
			errors.append(
				"Source frame %d time_s must be finite and non-negative" % index)
			continue
		if float(time_value) < previous_time:
			errors.append(
				"Source frame %d time_s must be non-decreasing" % index)
			continue
		previous_time = float(time_value)
		if not _integer(frame_id_value) or int(frame_id_value) < 0:
			errors.append(
				"Source frame %d original frame id must be non-negative" % index)
			continue
		var frame_id := int(frame_id_value)
		if seen_ids.has(frame_id):
			errors.append("Source repeats original frame id %d" % frame_id)
			continue
		seen_ids[frame_id] = true
		if records_value is Array and index < records_value.size():
			var record: Variant = records_value[index]
			if (
				not record is Dictionary
				or not _integer(record.get("frame"))
				or int(record.get("frame")) != frame_id
			):
				errors.append(
					"Source record %d must identify original frame %d" % [
						index, frame_id])
		entry["frame_id"] = frame_id
		entries.append(entry)
		playback.append({"frame": index, "time_s": float(time_value)})

	var first_texture: Variant = null
	if errors.is_empty():
		first_texture = source.load_texture(0)
		if not first_texture is Texture2D:
			errors.append("Source first frame texture is invalid")
	var presentation: Dictionary = {}
	if errors.is_empty() and include_presentation:
		var value: Variant = source.get_presentation()
		if not value is Dictionary:
			errors.append("Source presentation must be a Dictionary")
		else:
			presentation = value.duplicate(true)

	return {
		"errors": errors,
		"manifest": manifest,
		"records": records,
		"frame_entries": entries,
		"playback_frames": playback,
		"first_texture": first_texture,
		"presentation": presentation,
	}


func _integer(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
		and float(value) == floorf(float(value))
	)


func _positive_integer(value: Variant) -> bool:
	return _integer(value) and int(value) > 0


func _positive_number(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
		and float(value) > 0.0
	)


func _non_negative_number(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
		and float(value) >= 0.0
	)
