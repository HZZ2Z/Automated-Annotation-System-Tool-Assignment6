extends RefCounted
## 只遍历冻结快照；按帧/事件输出，生成阶段不保留整份修正投影和报告文本。
const DIFF = preload("res://client/feedback/annotation_diff.gd")
const CHUNK_BYTES = 65536

class Emitter extends RefCounted:
	var sink: Callable
	var token: Variant
	var hash := HashingContext.new()
	var bytes_written := 0
	var errors := PackedStringArray()
	var cancelled := false
	func _init(target: Callable, cancellation: Variant) -> void:
		sink = target
		token = cancellation
		hash.start(HashingContext.HASH_SHA256)
	func active() -> bool:
		if token != null and token.is_cancelled(): cancelled = true
		return errors.is_empty() and not cancelled
	func text(value: String) -> void:
		if not active(): return
		var bytes := value.to_utf8_buffer()
		for offset in range(0, bytes.size(), CHUNK_BYTES):
			if not active(): return
			var chunk := bytes.slice(offset, mini(offset + CHUNK_BYTES, bytes.size()))
			var error: String = sink.call(chunk)
			if not error.is_empty():
				errors.append(error)
				return
			hash.update(chunk)
			bytes_written += chunk.size()
	func result() -> Dictionary:
		active()
		return {"success":errors.is_empty() and not cancelled,"errors":errors,"cancelled":cancelled,"bytes":bytes_written,"sha256":hash.finish().hex_encode()}

static func emit_artifact(index: int, snapshot: Dictionary, prepared: Dictionary, sink: Callable, token: Variant = null) -> Dictionary:
	var out := Emitter.new(sink, token)
	if not sink.is_valid() or index < 0 or index > 4:
		out.errors.append("Invalid artifact stream or sink")
		return out.result()
	if not out.active(): return out.result()
	match index:
		0, 1: _records(index, snapshot, prepared, out)
		2: _diff_json(prepared.diff, out)
		3:
			out.text("frame_id,region_id,type,before,after\n")
			for frame in prepared.diff.frames:
				if not out.active(): break
				for event in frame.events:
					if not out.active(): break
					out.text(DIFF.csv_row([str(frame.frame_id),event.region_id,event.type,_json(event.before),_json(event.after)]))
		4:
			out.text("class," + ",".join(DIFF.CLASS_COUNTS) + "\n")
			for row in prepared.diff.by_class:
				if not out.active(): break
				var values = [row["class"]]
				for key in DIFF.CLASS_COUNTS: values.append(str(row[key]))
				out.text(DIFF.csv_row(values))
	return out.result()

static func _records(index: int, snapshot: Dictionary, prepared: Dictionary, out: Emitter) -> void:
	var selected := DIFF.dict_set(prepared.selected_frame_ids)
	var verified := DIFF.dict_set(prepared.verified_frame_ids)
	var explicit := DIFF.dict_set(snapshot.explicit_frames)
	var records := DIFF.records_by_frame(snapshot.records)
	for entry in snapshot.frame_entries:
		if not out.active(): break
		var frame := int(entry.frame_id)
		if not selected.has(frame): continue
		var record: Dictionary = records[frame]
		if index == 0:
			# source/filled 只在单帧投影中改变；冻结几何不被修改。
			var projected := record.duplicate()
			projected.source = "human_corrected"
			var regions := []
			for region in record.regions:
				if region.has("filled"):
					var clean: Dictionary = region.duplicate()
					clean.erase("filled")
					regions.append(clean)
				else: regions.append(region)
			projected.regions = regions
			out.text(_json(projected) + "\n")
		else:
			var mapped: Dictionary = entry.duplicate()
			mapped["sample_id"] = "%s_%06d" % [snapshot.media_id,frame]
			mapped["explicit"] = explicit.has(frame)
			mapped["verified"] = verified.has(frame)
			mapped["annotation_status"] = "negative" if record.regions.is_empty() and mapped.explicit else ("annotated" if mapped.explicit else "unannotated")
			mapped["review_status"] = "verified" if mapped.verified else "unverified"
			out.text(_json(mapped) + "\n")

static func _diff_json(diff: Dictionary, out: Emitter) -> void:
	var keys := diff.keys()
	keys.sort()
	out.text("{")
	for index in keys.size():
		if not out.active(): return
		if index: out.text(",")
		var key: String = keys[index]
		out.text(JSON.stringify(key) + ":")
		var value: Variant = diff[key]
		if value is Array:
			out.text("[")
			for item_index in value.size():
				if not out.active(): return
				if item_index: out.text(",")
				out.text(_json(value[item_index]))
			out.text("]")
		else: out.text(_json(value))
	out.text("}\n")

static func _json(value: Variant) -> String:
	return JSON.stringify(DIFF.normalize(value), "", true, true)
