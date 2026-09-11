extends RefCounted

const EXACT_JSON := preload("res://client/domain/exact_json.gd")
## Worker-only package service. It owns no live Store, SceneTree or mutable UI state.
const SEMANTICS = preload("res://client/feedback/package_semantics.gd")
const DIFF = preload("res://client/feedback/annotation_diff.gd")
const CODEC = preload("res://client/workspace/review_session_codec.gd")
const VALIDATOR = preload("res://client/domain/model_output_validator.gd")
const ARTIFACT_STREAM = preload("res://client/feedback/package_artifact_stream.gd")
const PATHS = ["data/corrected_annotations.jsonl", "data/frame_map.jsonl", "reports/diff.json", "reports/diff.csv", "reports/summary_by_class.csv"]

static func preview(snapshot: Dictionary, options: Dictionary, token = null) -> Dictionary:
	var result = {"success":false,"errors":PackedStringArray(),"summary":{},"diff":{},"revision":snapshot.get("revision",0),"session_id":snapshot.get("session_id", ""),"cancelled":false}
	if cancelled(token):
		result.cancelled = true
		return result
	result.errors = validate_snapshot(snapshot, token)
	if cancelled(token):
		result.cancelled = true
		return result
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
		var frame_verified = is_verified(snapshot, records[frame])
		if frame_verified: verified.append(frame)
		if kind == "review_export_v1" or frame_verified: selected.append(frame)
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
	var preview_started = Time.get_ticks_usec()
	var prepared = preview(snapshot, options, token)
	var timings = {"preview":(Time.get_ticks_usec()-preview_started)/1000.0,"artifact_write":0.0,"validation":0.0,"publication":0.0}
	var result = {"success":false,"errors":prepared.errors,"output_path":"","package_id":"","revision":snapshot.get("revision",0),"cancelled":prepared.cancelled,"reused":false,"summary":prepared.summary,"timings_ms":timings}
	if not prepared.success: return result
	var parent = String(options.get("output_parent", ""))
	result.errors.append_array(prepare_output_parent(parent,true))
	if not result.errors.is_empty(): return result
	var kind = options.get("kind", "training_update_v2")
	var selected = prepared.selected_frame_ids
	var selected_set = _id_set(selected)
	# 先用有界输出计算内容身份；只有新包才写盘，旧包仍先独立校验再复用。
	var artifact_started = Time.get_ticks_usec()
	var artifacts = []
	for index in PATHS.size():
		var emitted = ARTIFACT_STREAM.emit_artifact(index,snapshot,prepared,func(_chunk: PackedByteArray) -> String: return "",token)
		if not emitted.success:
			result.errors = emitted.errors
			result.cancelled = emitted.cancelled
			return result
		artifacts.append({"path":PATHS[index],"bytes":emitted.bytes,"sha256":emitted.sha256})
		progress(token,0.0,"Preparing artifact identity")
	timings["artifact_prepare"] = (Time.get_ticks_usec()-artifact_started)/1000.0
	var all_ids = []
	var excluded = []
	for entry in snapshot.frame_entries:
		all_ids.append(int(entry.frame_id))
		if not selected_set.has(int(entry.frame_id)): excluded.append(int(entry.frame_id))
	var manifest = {"schema_version":2 if kind == "training_update_v2" else 1,"package_type":kind,"tool":{"name":"Project6","version":"part4-v1"},"annotation_schema_version":1,"diff_schema_version":1,"frame_digits":6,"round_id":snapshot.round_id,"model_revision":snapshot.model_revision,"taxonomy_version":snapshot.taxonomy_version,"media":{"media_id":snapshot.media_id,"media_type":snapshot.media_type,"source":snapshot.source,"source_relative_path":snapshot.source_relative_path,"source_sha256":snapshot.source_sha256},"baseline":{"kind":snapshot.baseline_kind,"digest":snapshot.baseline_digest},"revision":snapshot.revision,"source_frame_entries":snapshot.frame_entries,"coverage":{"policy":"verified_only" if kind == "training_update_v2" else "all_frames_review","total_frames":all_ids.size(),"included_frames":selected.size(),"excluded_frames":excluded.size(),"source_frame_ids":all_ids,"included_frame_ids":selected,"excluded_frame_ids":excluded,"verified_frame_ids":prepared.verified_frame_ids,"explicit_frame_ids":snapshot.explicit_frames,"exclusion_reason":"not_content_verified" if kind == "training_update_v2" else "none"},"review_state":snapshot.review_state,"batch_operations":snapshot.batch_operations,"summary":prepared.summary,"artifacts":artifacts}
	manifest["package_id"] = package_identity(manifest)
	result.package_id = manifest.package_id
	var destination = parent.path_join("%s_%s_%s_%s" % [kind,snapshot.media_id,safe_component(snapshot.round_id),String(manifest.package_id).left(12)])
	result.output_path = destination
	if DirAccess.dir_exists_absolute(destination) or FileAccess.file_exists(destination):
		var validation_started = Time.get_ticks_usec()
		result.errors = validate_package(destination, manifest)
		timings.validation = (Time.get_ticks_usec()-validation_started)/1000.0
		result.success = result.errors.is_empty()
		result.reused = result.success
		return result
	if cancelled(token):
		result.cancelled = true
		return result
	# 只给本次新建包记录一次 UTC 秒时间；复用分支不生成或回写创建元数据。
	manifest["created_at"] = Time.get_datetime_string_from_system(true,false) + "Z"
	var staging = parent.path_join(".%s.tmp-%d-%d" % [destination.get_file(),OS.get_process_id(),Time.get_ticks_usec()])
	if DirAccess.dir_exists_absolute(staging) or FileAccess.file_exists(staging):
		result.errors.append("staging collision")
		return result
	if DirAccess.make_dir_absolute(staging) != OK:
		result.errors.append("cannot create staging directory")
		return result
	var write_started = Time.get_ticks_usec()
	for sub in ["data","reports"]:
		if DirAccess.make_dir_absolute(staging.path_join(sub)) != OK: result.errors.append("cannot create artifact directory")
	for i in PATHS.size():
		if cancelled(token):
			result.cancelled = true
			break
		if not result.errors.is_empty(): break
		var emitted = _write_artifact(staging.path_join(PATHS[i]),i,snapshot,prepared,token)
		result.errors.append_array(emitted.errors)
		result.cancelled = emitted.cancelled
		if emitted.success and (emitted.bytes != artifacts[i].bytes or emitted.sha256 != artifacts[i].sha256):
			result.errors.append("artifact generation differs from frozen content identity")
		progress(token, float(i+1)/7.0, "Writing package")
	if result.errors.is_empty() and not result.cancelled:
		result.errors.append_array(write_text(staging.path_join("manifest.json"),JSON.stringify(manifest,"",true,true)+"\n"))
	timings.artifact_write = (Time.get_ticks_usec()-write_started)/1000.0
	if result.errors.is_empty() and not result.cancelled:
		var validation_started = Time.get_ticks_usec()
		result.errors.append_array(validate_package(staging,manifest))
		timings.validation = (Time.get_ticks_usec()-validation_started)/1000.0
	if cancelled(token): result.cancelled = true
	if result.errors.is_empty() and not result.cancelled:
		# A competing destination must never be replaced, including an empty directory.
		var publication_started = Time.get_ticks_usec()
		if DirAccess.dir_exists_absolute(destination) or FileAccess.file_exists(destination): result.errors.append("destination appeared during export")
		elif DirAccess.rename_absolute(staging,destination) != OK: result.errors.append("atomic package publication failed")
		else:
			result.success = true
		timings.publication = (Time.get_ticks_usec()-publication_started)/1000.0
		if result.success: progress(token, 1.0, "Package published")
	if not result.success: remove_own_staging(staging)
	return result

static func _id_set(values: Array) -> Dictionary:
	var result = {}
	for value in values: result[int(value)] = true
	return result

static func validate_snapshot(snapshot: Dictionary, token = null) -> PackedStringArray:
	return CODEC.new().validate_snapshot(snapshot,token)

static func _write_artifact(path: String, index: int, snapshot: Dictionary, prepared: Dictionary, token) -> Dictionary:
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file == null:
		return {"success":false,"errors":PackedStringArray(["cannot open artifact: " + path.get_file()]),"cancelled":false}
	var sink := func(chunk: PackedByteArray) -> String:
		file.store_buffer(chunk)
		return "" if file.get_error() == OK else "artifact write failed"
	var result = ARTIFACT_STREAM.emit_artifact(index,snapshot,prepared,sink,token)
	if result.success:
		file.flush()
		if file.get_error() != OK:
			result.errors.append("artifact flush failed")
			result.success = false
	file.close()
	return result

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
	var manifest_text = _read_utf8_file(directory.path_join("manifest.json"),errors)
	if not errors.is_empty(): return errors
	var manifest = EXACT_JSON.parse_string(manifest_text)
	if not manifest is Dictionary: return PackedStringArray(["invalid package manifest"])
	var schemas = _load_schema_bundle(errors)
	if not errors.is_empty(): return errors
	errors.append_array(_manifest_schema_errors(manifest,schemas.manifest,"manifest",schemas.patterns))
	if not errors.is_empty(): return errors
	if manifest.has("created_at") and not _valid_created_at(manifest.created_at):
		return PackedStringArray(["manifest.created_at: expected a real Gregorian UTC timestamp YYYY-MM-DDTHH:MM:SSZ"])
	if not manifest.get("artifacts") is Array or manifest.artifacts.size() != PATHS.size(): return PackedStringArray(["invalid artifacts"])
	if manifest.get("package_id") != package_identity(manifest): errors.append("package identity mismatch")
	if not expected.is_empty() and manifest.get("package_id") != expected.get("package_id"): errors.append("conflicting existing package")
	var paths = {}
	var texts = {}
	for artifact in manifest.artifacts:
		if not artifact is Dictionary or artifact.get("path") not in PATHS:
			errors.append("unsafe or unsupported artifact path")
			continue
		var relative = artifact.path
		if paths.has(relative):
			errors.append("duplicate artifact")
			continue
		paths[relative] = true
		var file_path = directory.path_join(relative)
		var dir = DirAccess.open(file_path.get_base_dir())
		if dir == null or root == null or root.is_link(relative.get_base_dir()) or dir.is_link(relative.get_file()):
			errors.append("artifact symlinks or missing directories refused")
			continue
		if not FileAccess.file_exists(file_path):
			errors.append("artifact missing: " + relative)
			continue
		# 本次校验只读取一次：长度、摘要、解码与独立语义共用同一份字节。
		var raw = FileAccess.get_file_as_bytes(file_path)
		var hash = HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(raw)
		if raw.size() != artifact.get("bytes") or hash.finish().hex_encode() != artifact.get("sha256"):
			errors.append("artifact integrity mismatch: " + relative)
		texts[relative] = _decode_utf8(raw,relative,errors)
	if not expected.is_empty() and not DIFF.equivalent(manifest.artifacts,expected.artifacts): errors.append("artifact manifest conflict")
	if not errors.is_empty(): return errors
	var diff = EXACT_JSON.parse_string(texts[PATHS[2]])
	errors.append_array(_manifest_schema_errors(diff,schemas.diff,"diff",schemas.patterns))
	if errors.is_empty(): errors.append_array(SEMANTICS.validate(manifest,texts,diff))
	return errors

static func _read_utf8_file(path: String, errors: PackedStringArray) -> String:
	var file = FileAccess.open(path,FileAccess.READ)
	if file == null:
		errors.append("cannot read " + path.get_file())
		return ""
	var raw = file.get_buffer(file.get_length())
	file.close()
	return _decode_utf8(raw,path.get_file(),errors)

static func _decode_utf8(raw: PackedByteArray, path: String, errors: PackedStringArray) -> String:
	var text = raw.get_string_from_utf8()
	# Godot 默认会替换无效字节；回编码必须逐字节相同，才能交给 JSON/CSV 解析。
	if text.to_utf8_buffer() != raw: errors.append(path + ": invalid UTF-8")
	return text

static func _valid_created_at(value: Variant) -> bool:
	if not value is String or value.length() != 20: return false
	var regex = RegEx.new()
	regex.compile("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$")
	if regex.search(value) == null: return false
	var year = int(value.substr(0,4))
	if year < 1: return false
	var month = int(value.substr(5,2))
	var day = int(value.substr(8,2))
	var days = [31,29 if year % 400 == 0 or (year % 4 == 0 and year % 100 != 0) else 28,31,30,31,30,31,31,30,31,30,31]
	return day <= days[month-1]

static func _load_schema_bundle(errors: PackedStringArray) -> Dictionary:
	# 仅属于当前校验任务；预编译 pattern，递归冻结合同，避免跨线程可变缓存。
	var bundle = {}
	for entry in [["manifest","training-package-v2.schema.json"],["diff","annotation-diff-v1.schema.json"]]:
		var text = _read_utf8_file("res://core/feedback/" + entry[1],errors)
		var schema = EXACT_JSON.parse_string(text)
		if not schema is Dictionary:
			errors.append(entry[0] + " schema unavailable or invalid")
		else: bundle[entry[0]] = schema
	if not errors.is_empty(): return {}
	var diff_schema = bundle.diff.duplicate(true)
	var event_properties = _schema_path(diff_schema,["properties","frames","items","properties","events","items","properties"])
	if not event_properties is Dictionary:
		errors.append("audit schema has invalid event contract")
		return {}
	# Region contracts are checked by the same strict V1 validator below; no
	# second incomplete implementation of its referenced geometry schema.
	for field in ["before","after"]:
		event_properties[field] = {"type":["object","null"]}
	bundle.diff = diff_schema
	var patterns = {}
	_compile_schema_patterns(bundle,patterns,errors)
	bundle["patterns"] = patterns
	_freeze_schema(bundle)
	return bundle

static func _schema_path(schema: Variant, keys: Array) -> Variant:
	for key in keys:
		if not schema is Dictionary: return null
		schema = schema.get(key)
	return schema

static func _compile_schema_patterns(value: Variant, patterns: Dictionary, errors: PackedStringArray) -> void:
	if value is Dictionary:
		if value.has("pattern"):
			if not value.pattern is String: errors.append("schema pattern must be text")
			elif not patterns.has(value.pattern):
				var regex = RegEx.new()
				if regex.compile(value.pattern) != OK: errors.append("schema pattern is invalid")
				else: patterns[value.pattern] = regex
		for child in value.values(): _compile_schema_patterns(child,patterns,errors)
	elif value is Array:
		for child in value: _compile_schema_patterns(child,patterns,errors)

static func _freeze_schema(value: Variant) -> void:
	if value is Dictionary:
		for child in value.values(): _freeze_schema(child)
		value.make_read_only()
	elif value is Array:
		for child in value: _freeze_schema(child)
		value.make_read_only()

static func jsonl(values: Array) -> String:
	if values.is_empty(): return ""
	var lines = PackedStringArray()
	lines.resize(values.size())
	for index in values.size(): lines[index] = JSON.stringify(normalize(values[index]),"",true,true)
	return "\n".join(lines) + "\n"

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

# JSON-only storage callers use the generic safe directory checks. CSV package
# producers explicitly opt into project resource-import isolation.
static func prepare_output_parent(path: String, protect_package_reports: bool = false) -> PackedStringArray:
	if not path.is_absolute_path() or path.contains("\\") or ".." in path.split("/"):
		return PackedStringArray(["output_parent must be an absolute path without traversal"])
	var cursor = "/"
	for component in path.split("/",false):
		var directory = DirAccess.open(cursor)
		if directory != null and directory.is_link(component): return PackedStringArray(["output_parent symlink ancestors refused"])
		cursor = cursor.path_join(component)
		if FileAccess.file_exists(cursor): return PackedStringArray(["output_parent conflicts with a file"])
	if protect_package_reports:
		var import_errors = _guard_project_output(path.simplify_path().trim_suffix("/"))
		if not import_errors.is_empty(): return import_errors
	if DirAccess.make_dir_recursive_absolute(path) != OK: return PackedStringArray(["cannot create output_parent"])
	return PackedStringArray()

static func _guard_project_output(path: String) -> PackedStringArray:
	# Worker-only: CSV reports are data, but Godot otherwise imports them as
	# translation resources and can pollute or crash on a published package.
	var project_root = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	if path != project_root and not path.begins_with(project_root + "/"):
		return PackedStringArray()
	var output_root = project_root.path_join("output")
	if path == output_root or path.begins_with(output_root + "/"):
		var state = _ignore_marker_state(output_root)
		if state < 0: return PackedStringArray(["project output .gdignore conflicts with a directory or symlink"])
		if state == 1: return PackedStringArray()
		if DirAccess.make_dir_recursive_absolute(output_root) != OK:
			return PackedStringArray(["cannot create project output import guard directory"])
		# The sentinel belongs outside all package directories. Preserve any
		# existing marker bytes; never mark arbitrary project asset roots.
		return write_text(output_root.path_join(".gdignore"),"")
	var ancestor = path
	while true:
		var state = _ignore_marker_state(ancestor)
		if state < 0: return PackedStringArray(["output ancestor .gdignore conflicts with a directory or symlink"])
		if state == 1: return PackedStringArray()
		if ancestor == project_root: break
		ancestor = ancestor.get_base_dir()
	return PackedStringArray(["output_parent is an imported project asset path; choose res://output, an existing .gdignore-protected data directory, or an external directory"])

static func _ignore_marker_state(directory_path: String) -> int:
	var directory = DirAccess.open(directory_path)
	if directory == null: return 0
	var marker = directory_path.path_join(".gdignore")
	if directory.is_link(".gdignore") or DirAccess.dir_exists_absolute(marker): return -1
	return 1 if FileAccess.file_exists(marker) else 0

# Evaluate only the keywords used by our local manifest contract. Unknown keywords
# fail closed so a future schema extension cannot silently bypass reuse validation.
static func _manifest_schema_errors(value: Variant, schema: Dictionary, path: String, patterns: Dictionary = {}) -> PackedStringArray:
	var errors = PackedStringArray()
	for key in schema:
		if key not in ["$schema","$id","$defs","type","const","enum","oneOf","properties","required","additionalProperties","propertyNames","dependentRequired","items","minItems","maxItems","uniqueItems","pattern","minLength","maxLength","minimum","maximum","exclusiveMinimum"]:
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
			if _manifest_schema_errors(value,branch,path,patterns).is_empty(): matches += 1
		if matches != 1: errors.append(path + ": must match one schema branch")
	if value is Dictionary:
		var properties = schema.get("properties",{})
		for key in schema.get("required",[]):
			if not value.has(key): errors.append(path + ": missing " + key)
		for key in value:
			if schema.has("propertyNames"): errors.append_array(_manifest_schema_errors(key,schema.propertyNames,path + ".key",patterns))
			if properties.has(key): errors.append_array(_manifest_schema_errors(value[key],properties[key],path + "." + key,patterns))
			elif schema.get("additionalProperties") is Dictionary: errors.append_array(_manifest_schema_errors(value[key],schema.additionalProperties,path + "." + key,patterns))
			elif schema.get("additionalProperties",true) == false: errors.append(path + ": unexpected " + key)
		for key in schema.get("dependentRequired",{}):
			if value.has(key):
				for dependency in schema.dependentRequired[key]:
					if not value.has(dependency): errors.append(path + ": missing dependent " + dependency)
	if value is Array:
		if value.size() < schema.get("minItems",0) or value.size() > schema.get("maxItems",value.size()): errors.append(path + ": invalid array length")
		var seen = {}
		for index in value.size():
			if schema.has("items"): errors.append_array(_manifest_schema_errors(value[index],schema.items,path + "." + str(index),patterns))
			if schema.get("uniqueItems",false):
				var canonical = JSON.stringify(normalize(value[index]),"",true,true)
				if seen.has(canonical): errors.append(path + ": duplicate item")
				seen[canonical] = true
	if value is String:
		if value.length() < schema.get("minLength",0): errors.append(path + ": text too short")
		if value.length() > schema.get("maxLength",value.length()): errors.append(path + ": text too long")
		if schema.has("pattern"):
			var regex = patterns.get(schema.pattern)
			if regex == null:
				regex = RegEx.new()
				if regex.compile(schema.pattern) != OK: errors.append(path + ": invalid schema pattern"); return errors
			if regex.search(value) == null: errors.append(path + ": invalid text pattern")
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
