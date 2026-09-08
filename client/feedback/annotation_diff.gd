extends RefCounted
## Pure final-state audit. Region identity is scoped to an original source frame.
const CATEGORIES = ["added", "deleted", "label_changed", "geometry_changed", "attributes_changed"]
const CLASS_COUNTS = ["added", "deleted", "reclassified_in", "reclassified_out", "geometry_changed", "attributes_changed"]

static func build_diff(snapshot: Dictionary, frame_ids: Array) -> Dictionary:
	var summary = counts()
	var ids = frame_ids.duplicate()
	ids.sort()
	ids = Array(dict_set(ids).keys())
	summary.merge({"total_frames":snapshot.get("frame_entries", []).size(), "included_frames":ids.size(), "excluded_frames":snapshot.get("frame_entries", []).size() - ids.size(), "changed_frames":0, "changed_regions":0})
	var result = {"schema_version":1,"available":snapshot.get("baseline_kind", "unknown") != "unknown","frames":[],"summary":summary,"by_class":[]}
	if not result.available: return result
	var before = records_by_frame(snapshot.get("baseline_records", []))
	var after = records_by_frame(snapshot.get("records", []))
	var classes = {}
	for frame in ids:
		var old = regions_by_id(before.get(frame, {}).get("regions", []))
		var new = regions_by_id(after.get(frame, {}).get("regions", []))
		var region_ids = old.duplicate()
		region_ids.merge(new)
		var sorted_ids = region_ids.keys()
		sorted_ids.sort()
		var row = {"frame_id":frame,"events":[],"counts":counts(),"changed_regions":0}
		for id in sorted_ids:
			var previous = old.get(id)
			var current = new.get(id)
			var types = []
			if previous == null: types.append("added")
			elif current == null: types.append("deleted")
			else:
				if previous["class"] != current["class"]: types.append("label_changed")
				if not equivalent(fields(previous, ["box","polygon"]), fields(current, ["box","polygon"])): types.append("geometry_changed")
				if not equivalent(fields(previous, ["kind","track_id","conf"]), fields(current, ["kind","track_id","conf"])): types.append("attributes_changed")
			if not types.is_empty(): row.changed_regions += 1
			for type in types:
				row.events.append({"region_id":id,"type":type,"before":previous,"after":current})
				row.counts[type] += 1
				summary[type] += 1
				if type == "label_changed":
					class_increment(classes, previous["class"], "reclassified_out")
					class_increment(classes, current["class"], "reclassified_in")
				else: class_increment(classes, previous["class"] if type == "deleted" else current["class"], type)
		if row.changed_regions > 0: summary.changed_frames += 1
		summary.changed_regions += row.changed_regions
		result.frames.append(row)
	var labels = classes.keys()
	labels.sort()
	for label in labels: result.by_class.append(classes[label])
	return result

static func equivalent(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float): return a == b
	if typeof(a) != typeof(b): return false
	if a is Dictionary:
		if a.size() != b.size(): return false
		for key in a:
			if not b.has(key) or not equivalent(a[key], b[key]): return false
		return true
	if a is Array:
		if a.size() != b.size(): return false
		for i in a.size():
			if not equivalent(a[i], b[i]): return false
		return true
	return a == b

static func fields(value: Dictionary, names: Array) -> Dictionary:
	var out = {}
	for name in names:
		if value.has(name): out[name] = value[name]
	return out

static func counts() -> Dictionary:
	var out = {}
	for key in CATEGORIES: out[key] = 0
	return out

static func dict_set(values: Array) -> Dictionary:
	var out = {}
	for value in values: out[value] = true
	return out

static func records_by_frame(records: Array) -> Dictionary:
	var out = {}
	for record in records: out[int(record.frame)] = record
	return out

static func regions_by_id(regions: Array) -> Dictionary:
	var out = {}
	for region in regions:
		var copy = region.duplicate(true)
		copy.erase("filled")
		out[region.id] = copy
	return out

static func class_increment(classes: Dictionary, label: String, field: String) -> void:
	if not classes.has(label):
		classes[label] = {"class":label}
		for key in CLASS_COUNTS: classes[label][key] = 0
	classes[label][field] += 1

static func events_csv(diff: Dictionary) -> String:
	var chunks = PackedStringArray(["frame_id,region_id,type,before,after\n"])
	for frame in diff.frames:
		for event in frame.events:
			chunks.append(csv_row([str(frame.frame_id), event.region_id, event.type, JSON.stringify(normalize(event.before),"",true,true), JSON.stringify(normalize(event.after),"",true,true)]))
	return "".join(chunks)

static func classes_csv(diff: Dictionary) -> String:
	var chunks = PackedStringArray(["class," + ",".join(CLASS_COUNTS) + "\n"])
	for row in diff.by_class:
		var values = [row["class"]]
		for key in CLASS_COUNTS: values.append(str(row[key]))
		chunks.append(csv_row(values))
	return "".join(chunks)

static func csv_row(values: Array) -> String:
	var escaped = PackedStringArray()
	for value in values: escaped.append('"' + String(value).replace('"','""') + '"')
	return ",".join(escaped) + "\n"

static func normalize(value: Variant) -> Variant:
	if value is Dictionary:
		var out = {}
		for key in value: out[key] = normalize(value[key])
		return out
	if value is Array:
		var out = []
		for item in value: out.append(normalize(item))
		return out
	if value is int or value is float: return float(value) if value != 0 else 0.0
	return value
