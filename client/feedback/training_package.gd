extends RefCounted

const EXACT_JSON := preload("res://client/domain/exact_json.gd")
## Worker-only package service. It owns no live Store, SceneTree or mutable UI state.
const DIFF = preload("res://client/feedback/annotation_diff.gd")
const CODEC = preload("res://client/workspace/review_session_codec.gd")
const VALIDATOR = preload("res://client/domain/model_output_validator.gd")
const PATHS = ["data/corrected_annotations.jsonl", "data/frame_map.jsonl", "reports/diff.json", "reports/diff.csv", "reports/summary_by_class.csv"]

static func preview(snapshot: Dictionary, options: Dictionary, token = null) -> Dictionary:
	var result = {"success":false,"errors":PackedStringArray(),"summary":{},"diff":{},"revision":snapshot.get("revision",0),"session_id":snapshot.get("session_id", ""),"cancelled":false}
	if cancelled(token):
		result.cancelled = true
		return result
	result.errors = validate_snapshot(snapshot)
	var kind = options.get("kind", "training_update_v2")
	if kind not in ["training_update_v2","review_export_v1"]: result.errors.append("unsupported package kind")
	if not result.errors.is_empty(): return result
	if kind == "training_update_v2" and snapshot.baseline_kind == "unknown":
		result.errors.append("training requires a known baseline")
		return result
	var selected = []
	var verified = []
	var records = DIFF.records_by_frame(snapshot.records)
	for entry in snapshot.frame_entries:
		var frame = int(entry.frame_id)
		if is_verified(snapshot, records[frame]): verified.append(frame)
		if kind == "review_export_v1" or frame in verified: selected.append(frame)
	if kind == "training_update_v2" and selected.is_empty():
		result.errors.append("training requires at least one content-verified frame")
		return result
	result.diff = DIFF.build_diff(snapshot, selected)
	result.summary = result.diff.summary.duplicate(true)
	result.summary["verified_frames"] = verified.size()
	result.summary["audit_available"] = result.diff.available
	result["selected_frame_ids"] = selected
	result["verified_frame_ids"] = verified
	result.success = true
	return result

static func export_package(snapshot: Dictionary, options: Dictionary, token = null) -> Dictionary:
	var prepared = preview(snapshot, options, token)
	var result = {"success":false,"errors":prepared.errors,"output_path":"","package_id":"","revision":snapshot.get("revision",0),"cancelled":prepared.cancelled,"reused":false,"summary":prepared.summary}
	if not prepared.success: return result
	var parent = String(options.get("output_parent", ""))
	result.errors.append_array(prepare_output_parent(parent))
	if not result.errors.is_empty(): return result
	var kind = options.get("kind", "training_update_v2")
	var selected = prepared.selected_frame_ids
	var records = DIFF.records_by_frame(snapshot.records)
	var corrected = []
	var frame_map = []
	for entry in snapshot.frame_entries:
		var frame = int(entry.frame_id)
		if frame not in selected: continue
		var record = project_record(records[frame])
		record.source = "human_corrected"
		corrected.append(record)
		var mapped = entry.duplicate(true)
		mapped["sample_id"] = "%s_%06d" % [snapshot.media_id,frame]
		mapped["explicit"] = frame in snapshot.explicit_frames
		mapped["verified"] = frame in prepared.verified_frame_ids
		mapped["annotation_status"] = "negative" if record.regions.is_empty() and mapped.explicit else ("annotated" if mapped.explicit else "unannotated")
		mapped["review_status"] = "verified" if mapped.verified else "unverified"
		frame_map.append(mapped)
	var texts = [jsonl(corrected), jsonl(frame_map), JSON.stringify(normalize(prepared.diff),"",true,true) + "\n", DIFF.events_csv(prepared.diff), DIFF.classes_csv(prepared.diff)]
	var artifacts = []
	for i in PATHS.size(): artifacts.append({"path":PATHS[i],"bytes":texts[i].to_utf8_buffer().size(),"sha256":texts[i].sha256_text()})
	var all_ids = []
	var excluded = []
	for entry in snapshot.frame_entries:
		all_ids.append(int(entry.frame_id))
		if int(entry.frame_id) not in selected: excluded.append(int(entry.frame_id))
	var manifest = {"schema_version":2 if kind == "training_update_v2" else 1,"package_type":kind,"tool":{"name":"Project6","version":"part4-v1"},"annotation_schema_version":1,"diff_schema_version":1,"frame_digits":6,"round_id":snapshot.round_id,"model_revision":snapshot.model_revision,"taxonomy_version":snapshot.taxonomy_version,"media":{"media_id":snapshot.media_id,"media_type":snapshot.media_type,"source":snapshot.source,"source_relative_path":snapshot.source_relative_path,"source_sha256":snapshot.source_sha256},"baseline":{"kind":snapshot.baseline_kind,"digest":snapshot.baseline_digest},"revision":snapshot.revision,"source_frame_entries":snapshot.frame_entries,"coverage":{"total_frames":all_ids.size(),"included_frames":selected.size(),"excluded_frames":excluded.size(),"source_frame_ids":all_ids,"included_frame_ids":selected,"excluded_frame_ids":excluded,"verified_frame_ids":prepared.verified_frame_ids,"explicit_frame_ids":snapshot.explicit_frames,"exclusion_reason":"not_content_verified" if kind == "training_update_v2" else "none"},"review_state":snapshot.review_state,"batch_operations":snapshot.batch_operations,"summary":prepared.summary,"artifacts":artifacts}
	manifest["package_id"] = package_identity(manifest)
	result.package_id = manifest.package_id
	var destination = parent.path_join("%s_%s_%s_%s" % [kind,snapshot.media_id,safe_component(snapshot.round_id),String(manifest.package_id).left(12)])
	result.output_path = destination
	if DirAccess.dir_exists_absolute(destination) or FileAccess.file_exists(destination):
		result.errors = validate_package(destination, manifest)
		result.success = result.errors.is_empty()
		result.reused = result.success
		return result
	if cancelled(token):
		result.cancelled = true
		return result
	var staging = parent.path_join(".%s.tmp-%d-%d" % [destination.get_file(),OS.get_process_id(),Time.get_ticks_usec()])
	if DirAccess.dir_exists_absolute(staging) or FileAccess.file_exists(staging):
		result.errors.append("staging collision")
		return result
	if DirAccess.make_dir_absolute(staging) != OK:
		result.errors.append("cannot create staging directory")
		return result
	for sub in ["data","reports"]:
		if DirAccess.make_dir_absolute(staging.path_join(sub)) != OK: result.errors.append("cannot create artifact directory")
	for i in PATHS.size():
		if cancelled(token):
			result.cancelled = true
			break
		if not result.errors.is_empty(): break
		result.errors.append_array(write_text(staging.path_join(PATHS[i]),texts[i]))
		progress(token, float(i+1)/7.0, "Writing package")
	if result.errors.is_empty() and not result.cancelled:
		result.errors.append_array(write_text(staging.path_join("manifest.json"),JSON.stringify(manifest,"",true,true)+"\n"))
		result.errors.append_array(validate_package(staging,manifest))
	if cancelled(token): result.cancelled = true
	if result.errors.is_empty() and not result.cancelled:
		# A competing destination must never be replaced, including an empty directory.
		if DirAccess.dir_exists_absolute(destination) or FileAccess.file_exists(destination): result.errors.append("destination appeared during export")
		elif DirAccess.rename_absolute(staging,destination) != OK: result.errors.append("atomic package publication failed")
		else:
			result.success = true
			progress(token, 1.0, "Package published")
	if not result.success: remove_own_staging(staging)
	return result

static func validate_snapshot(snapshot: Dictionary) -> PackedStringArray:
	var errors = PackedStringArray()
	for key in ["records","baseline_records","frame_entries","explicit_frames","batch_operations"]:
		if not snapshot.get(key) is Array: errors.append("snapshot.%s: expected Array" % key)
	if not snapshot.get("review_state") is Dictionary: errors.append("snapshot.review_state: expected Dictionary")
	if not errors.is_empty(): return errors
	var validator = VALIDATOR.new()
	var seen = {}
	for record in snapshot.records:
		if not record is Dictionary:
			errors.append("snapshot.records: malformed record")
			continue
		errors.append_array(validator.validate_record(project_record(record)))
		if seen.has(record.get("frame")): errors.append("snapshot.records: duplicate frame")
		seen[record.get("frame")] = true
	if not errors.is_empty(): return errors
	var codec = CODEC.new()
	var decoded = codec.decode(codec.encode(snapshot))
	errors.append_array(decoded.errors)
	if not errors.is_empty(): return errors
	if not DIFF.equivalent(canonical_records(snapshot.records),canonical_records(decoded.snapshot.records)):
		errors.append("snapshot.records differ from complete explicit/baseline frame reconstruction")
	return errors

static func canonical_records(records: Array) -> Array:
	var out = []
	for record in records: out.append(project_record(record))
	out.sort_custom(func(a,b): return a.frame < b.frame)
	return out

static func project_record(record: Dictionary) -> Dictionary:
	var out = record.duplicate(true)
	if out.get("regions") is Array:
		for region in out.regions:
			if region is Dictionary: region.erase("filled")
	return out

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

static func is_verified(snapshot: Dictionary, record: Dictionary) -> bool:
	var digest = JSON.stringify(normalize(project_record(record)),"",true,true).sha256_text()
	return snapshot.review_state.get(str(int(record.frame)),{}).get("accepted_digest") == digest

static func package_identity(manifest: Dictionary) -> String:
	var identity = manifest.duplicate(true)
	for field in ["package_id","revision","created_at"]: identity.erase(field)
	return JSON.stringify(normalize(identity),"",true,true).sha256_text()

static func validate_package(directory: String, expected: Dictionary = {}) -> PackedStringArray:
	var errors = PackedStringArray()
	var parent = DirAccess.open(directory.get_base_dir())
	var root = DirAccess.open(directory)
	if parent == null or root == null or parent.is_link(directory.get_file()): return PackedStringArray(["package must be a real directory"])
	if Array(root.get_files()) != ["manifest.json"] or Array(root.get_directories()) != ["data","reports"]: return PackedStringArray(["package contains missing or foreign entries"])
	for sub in ["data","reports"]:
		if root.is_link(sub): return PackedStringArray(["package directory links refused"])
		var child = DirAccess.open(directory.path_join(sub))
		var expected_files = ["corrected_annotations.jsonl","frame_map.jsonl"] if sub == "data" else ["diff.csv","diff.json","summary_by_class.csv"]
		if child == null or not child.get_directories().is_empty() or Array(child.get_files()) != expected_files: return PackedStringArray(["artifact directory contains missing or foreign entries"])
	if root.is_link("manifest.json"): return PackedStringArray(["manifest link refused"])
	var manifest = EXACT_JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("manifest.json")))
	if not manifest is Dictionary: return PackedStringArray(["invalid package manifest"])
	var schema = EXACT_JSON.parse_string(FileAccess.get_file_as_string("res://core/feedback/training-package-v2.schema.json"))
	if not schema is Dictionary: return PackedStringArray(["package manifest schema unavailable"])
	errors.append_array(_manifest_schema_errors(manifest,schema,"manifest"))
	if not errors.is_empty(): return errors
	if not manifest.get("artifacts") is Array or manifest.artifacts.size() != PATHS.size(): return PackedStringArray(["invalid artifacts"])
	if manifest.get("package_id") != package_identity(manifest): errors.append("package identity mismatch")
	if not expected.is_empty() and manifest.get("package_id") != expected.get("package_id"): errors.append("conflicting existing package")
	var paths = []
	for artifact in manifest.artifacts:
		if not artifact is Dictionary or artifact.get("path") not in PATHS:
			errors.append("unsafe or unsupported artifact path")
			continue
		var relative = artifact.path
		if relative in paths: errors.append("duplicate artifact")
		paths.append(relative)
		var file_path = directory.path_join(relative)
		var dir = DirAccess.open(file_path.get_base_dir())
		if dir == null or root == null or root.is_link(relative.get_base_dir()) or dir.is_link(relative.get_file()):
			errors.append("artifact symlinks or missing directories refused")
			continue
		if not FileAccess.file_exists(file_path) or FileAccess.get_sha256(file_path) != artifact.get("sha256") or FileAccess.get_file_as_bytes(file_path).size() != artifact.get("bytes"):
			errors.append("artifact integrity mismatch: " + relative)
	if not expected.is_empty() and not DIFF.equivalent(manifest.artifacts,expected.artifacts): errors.append("artifact manifest conflict")
	return errors

static func jsonl(values: Array) -> String:
	var out = ""
	for value in values: out += JSON.stringify(normalize(value),"",true,true) + "\n"
	return out

static func write_text(path: String, text: String) -> PackedStringArray:
	var file = FileAccess.open(path,FileAccess.WRITE)
	if file == null: return PackedStringArray(["cannot open artifact: " + path.get_file()])
	file.store_string(text)
	file.flush()
	var error = file.get_error()
	file.close()
	return PackedStringArray() if error == OK else PackedStringArray(["artifact write failed"])

static func safe_component(value: String) -> String:
	var regex = RegEx.new()
	regex.compile("[^A-Za-z0-9_.-]")
	return regex.sub(value,"_",true).left(80)

static func cancelled(token) -> bool:
	return token != null and token.is_cancelled()

static func progress(token, fraction: float, message: String) -> void:
	if token != null and token.has_method("report_progress"): token.report_progress({"fraction":fraction,"message":message})

static func remove_own_staging(path: String) -> void:
	# Called only with the unique directory successfully created by this invocation.
	var directory = DirAccess.open(path)
	if directory == null: return
	for name in directory.get_files(): DirAccess.remove_absolute(path.path_join(name))
	for name in directory.get_directories():
		if directory.is_link(name): DirAccess.remove_absolute(path.path_join(name))
		else: remove_own_staging(path.path_join(name))
	DirAccess.remove_absolute(path)

static func prepare_output_parent(path: String) -> PackedStringArray:
	if not path.is_absolute_path() or path.contains("\\") or ".." in path.split("/"):
		return PackedStringArray(["output_parent must be an absolute path without traversal"])
	var cursor = "/"
	for component in path.split("/",false):
		var directory = DirAccess.open(cursor)
		if directory != null and directory.is_link(component): return PackedStringArray(["output_parent symlink ancestors refused"])
		cursor = cursor.path_join(component)
		if FileAccess.file_exists(cursor): return PackedStringArray(["output_parent conflicts with a file"])
	if DirAccess.make_dir_recursive_absolute(path) != OK: return PackedStringArray(["cannot create output_parent"])
	return PackedStringArray()

# Evaluate only the keywords used by our local manifest contract. Unknown keywords
# fail closed so a future schema extension cannot silently bypass reuse validation.
static func _manifest_schema_errors(value: Variant, schema: Dictionary, path: String) -> PackedStringArray:
	var errors = PackedStringArray()
	for key in schema:
		if key not in ["$schema","$id","$defs","type","const","enum","oneOf","properties","required","additionalProperties","propertyNames","dependentRequired","items","minItems","maxItems","uniqueItems","pattern","minLength","minimum","maximum","exclusiveMinimum"]:
			errors.append(path + ": unsupported manifest schema keyword " + key)
	if schema.has("type"):
		var types = schema.type if schema.type is Array else [schema.type]
		var valid = false
		for type in types:
			valid = valid or _schema_type(value,type)
		if not valid: return PackedStringArray([path + ": invalid type"])
	if schema.has("const") and not DIFF.equivalent(value,schema.const): errors.append(path + ": invalid constant")
	if schema.has("enum"):
		var found = false
		for candidate in schema.enum:
			if DIFF.equivalent(value,candidate): found = true
		if not found: errors.append(path + ": invalid enum")
	if schema.has("oneOf"):
		var matches = 0
		for branch in schema.oneOf:
			if _manifest_schema_errors(value,branch,path).is_empty(): matches += 1
		if matches != 1: errors.append(path + ": must match one schema branch")
	if value is Dictionary:
		var properties = schema.get("properties",{})
		for key in schema.get("required",[]):
			if not value.has(key): errors.append(path + ": missing " + key)
		for key in value:
			if schema.has("propertyNames"): errors.append_array(_manifest_schema_errors(key,schema.propertyNames,path + ".key"))
			if properties.has(key): errors.append_array(_manifest_schema_errors(value[key],properties[key],path + "." + key))
			elif schema.get("additionalProperties") is Dictionary: errors.append_array(_manifest_schema_errors(value[key],schema.additionalProperties,path + "." + key))
			elif schema.get("additionalProperties",true) == false: errors.append(path + ": unexpected " + key)
		for key in schema.get("dependentRequired",{}):
			if value.has(key):
				for dependency in schema.dependentRequired[key]:
					if not value.has(dependency): errors.append(path + ": missing dependent " + dependency)
	if value is Array:
		if value.size() < schema.get("minItems",0) or value.size() > schema.get("maxItems",value.size()): errors.append(path + ": invalid array length")
		var seen = {}
		for index in value.size():
			if schema.has("items"): errors.append_array(_manifest_schema_errors(value[index],schema.items,path + "." + str(index)))
			if schema.get("uniqueItems",false):
				var canonical = JSON.stringify(normalize(value[index]),"",true,true)
				if seen.has(canonical): errors.append(path + ": duplicate item")
				seen[canonical] = true
	if value is String:
		if value.length() < schema.get("minLength",0): errors.append(path + ": text too short")
		if schema.has("pattern"):
			var regex = RegEx.new()
			if regex.compile(schema.pattern) != OK or regex.search(value) == null: errors.append(path + ": invalid text pattern")
	if value is int or value is float:
		if not is_finite(float(value)): errors.append(path + ": nonfinite number")
		if schema.has("minimum") and value < schema.minimum: errors.append(path + ": below minimum")
		if schema.has("maximum") and value > schema.maximum: errors.append(path + ": above maximum")
		if schema.has("exclusiveMinimum") and value <= schema.exclusiveMinimum: errors.append(path + ": below exclusive minimum")
	return errors

static func _schema_type(value: Variant, type: String) -> bool:
	match type:
		"object": return value is Dictionary
		"array": return value is Array
		"string": return value is String
		"boolean": return value is bool
		"null": return value == null
		"number": return (value is int or value is float) and is_finite(float(value))
		"integer": return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value))
	return false
