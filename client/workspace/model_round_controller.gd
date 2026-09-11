extends RefCounted

const EXACT_JSON := preload("res://client/domain/exact_json.gd")
## Worker-only two-phase round/baseline transaction. Never reads a live UI Store.
const REPO = preload("res://client/workspace/session_repository.gd")
const CODEC = preload("res://client/workspace/review_session_codec.gd")
const DOCUMENT = preload("res://client/workspace/atomic_document.gd")
const PACKAGE = preload("res://client/feedback/training_package.gd")
const STORE = preload("res://client/domain/annotation_store.gd")
const VALIDATOR = preload("res://client/domain/model_output_validator.gd")
const BASELINE_RESOLVER = preload("res://client/workspace/export_baseline_resolver.gd")

static func prepare_round(context: Dictionary, input_path: String, token = null) -> Dictionary:
	return _prepare(context,input_path,false,token)

static func prepare_baseline_binding(context: Dictionary, input_path: String, token = null) -> Dictionary:
	return _prepare(context,input_path,true,token)

static func commit_round(context: Dictionary, prepared: Dictionary, token = null) -> Dictionary:
	return _commit(context,prepared,false,token)

static func commit_baseline_binding(context: Dictionary, prepared: Dictionary, token = null) -> Dictionary:
	return _commit(context,prepared,true,token)

static func prepare_auto_baseline_binding(context: Dictionary, descriptor: Dictionary, token = null) -> Dictionary:
	return _prepare_auto_baseline_binding(context,descriptor,token)

static func commit_auto_baseline_binding(context: Dictionary, prepared: Dictionary, descriptor: Dictionary, token = null) -> Dictionary:
	if not prepared.get("success",false) or prepared.get("operation") != "auto_binding":
		return _failure("Expected a successfully prepared automatic baseline candidate")
	var fresh = _prepare_auto_baseline_binding(context,descriptor,token)
	if not fresh.success: return fresh
	if fresh.source_sha256 != prepared.get("source_sha256"):
		return _failure("Original baseline changed before binding")
	return _commit_prepared_binding(
		context,
		prepared,
		fresh,
		token,
		["path","source_sha256","descriptor","active_sha256","candidate_sha256"],
	)

static func import_round(context: Dictionary, input_path: String, token = null) -> Dictionary:
	var prepared = prepare_round(context,input_path,token)
	return commit_round(context,prepared,token) if prepared.success else prepared

static func _prepare_auto_baseline_binding(context: Dictionary, descriptor: Dictionary, token) -> Dictionary:
	if PACKAGE.cancelled(token): return _failure("Round operation cancelled")
	if not context.get("snapshot") is Dictionary or not context.get("save_options") is Dictionary:
		return _failure("Round context requires frozen snapshot and save_options")
	var snapshot = context.snapshot
	var errors = PACKAGE.validate_snapshot(snapshot)
	if not errors.is_empty(): return _failure("Invalid current session: " + "; ".join(errors))
	if snapshot.baseline_kind != "unknown": return _failure("Only an unknown legacy baseline can be bound")
	var document = DOCUMENT.new()
	var path = String(context.save_options.get("path",""))
	var read = document.read_document(path)
	if not read.success: return read
	if read.sha256 != context.save_options.get("expected_sha256") or not PACKAGE.DIFF.equivalent(read.payload,CODEC.new().encode(snapshot)):
		return _failure("Save the complete current session successfully before importing; active document changed or has unsaved edits")
	var resolved = BASELINE_RESOLVER.new().resolve(snapshot,descriptor,token)
	if not resolved.success:
		return _failure("Cannot resolve original baseline: " + "; ".join(resolved.errors))
	var binding = _prepare_binding_candidate(snapshot,resolved.records,"imported_labels",token)
	if not binding.success: return binding
	return {
		"success":true,
		"errors":[],
		"snapshot":binding.snapshot,
		"store":binding.store,
		"source_sha256":resolved.source_sha256,
		"descriptor":resolved.descriptor,
		"active_sha256":read.sha256,
		"candidate_sha256":_snapshot_digest(binding.snapshot),
		"operation":"auto_binding",
		"path":path,
	}

static func _prepare(context: Dictionary, input_path: String, binding: bool, token) -> Dictionary:
	if PACKAGE.cancelled(token): return _failure("Round operation cancelled")
	if not context.get("snapshot") is Dictionary or not context.get("save_options") is Dictionary:
		return _failure("Round context requires frozen snapshot and save_options")
	var snapshot = context.snapshot
	var errors = PACKAGE.validate_snapshot(snapshot)
	if not errors.is_empty(): return _failure("Invalid current session: " + "; ".join(errors))
	var document = DOCUMENT.new()
	var path = String(context.save_options.get("path",""))
	var read = document.read_document(path)
	if not read.success: return read
	if read.sha256 != context.save_options.get("expected_sha256") or not PACKAGE.DIFF.equivalent(read.payload,CODEC.new().encode(snapshot)):
		return _failure("Save the complete current session successfully before importing; active document changed or has unsaved edits")
	var manifest = {}
	var annotation_path = input_path
	var input_sha = ""
	var parent_sha = ""
	if binding:
		if snapshot.baseline_kind != "unknown": return _failure("Only an unknown legacy baseline can be bound")
	else:
		var input = document.read_document(input_path)
		if not input.success: return input
		manifest = input.payload
		input_sha = input.sha256
		var schema = EXACT_JSON.parse_string(FileAccess.get_file_as_string("res://core/feedback/model-round-v1.schema.json"))
		if not schema is Dictionary: return _failure("Model round schema unavailable")
		errors = PACKAGE._manifest_schema_errors(manifest,schema,"model_round")
		if not errors.is_empty(): return _failure("; ".join(errors))
		if manifest.round_id.strip_edges().is_empty() or manifest.round_id == snapshot.round_id:
			return _failure("Returned round_id must be nonempty and distinct from the current round")
		if manifest.taxonomy_version != snapshot.taxonomy_version or not PACKAGE.DIFF.equivalent(manifest.media,_media(snapshot)) or not PACKAGE.DIFF.equivalent(manifest.source_frame_entries,snapshot.frame_entries):
			return _failure("Model round media, taxonomy or complete source frame mapping mismatch")
		var parent_path = String(context.get("parent_package_path",""))
		if parent_path.is_empty(): return _failure("Select the parent training package directory")
		errors = PACKAGE.validate_package(parent_path)
		if not errors.is_empty(): return _failure("Invalid parent package: " + "; ".join(errors))
		var parent = document.read_document(parent_path.path_join("manifest.json"))
		if not parent.success: return parent
		parent_sha = parent.sha256
		var p = parent.payload
		if p.package_type != "training_update_v2" or p.package_id != manifest.parent_package_id or p.round_id != snapshot.round_id or p.model_revision != snapshot.model_revision or p.taxonomy_version != snapshot.taxonomy_version or not PACKAGE.DIFF.equivalent(p.media,_media(snapshot)) or not PACKAGE.DIFF.equivalent(p.baseline,{"kind":snapshot.baseline_kind,"digest":snapshot.baseline_digest}) or not PACKAGE.DIFF.equivalent(p.source_frame_entries,snapshot.frame_entries):
			return _failure("Parent training package does not belong to this media, baseline and round")
		annotation_path = input_path.get_base_dir().path_join(manifest.annotations.path)
	var loaded = _read_records(annotation_path)
	if not loaded.success: return loaded
	if not binding and (loaded.sha256 != manifest.annotations.sha256 or loaded.bytes != manifest.annotations.bytes):
		return _failure("Returned model annotation bytes/SHA256 mismatch")
	var candidate: Dictionary
	var store
	if binding:
		var binding_candidate = _prepare_binding_candidate(snapshot,loaded.records,"model",token)
		if not binding_candidate.success: return binding_candidate
		candidate = binding_candidate.snapshot
		store = binding_candidate.store
	else:
		candidate = snapshot.duplicate(true)
		candidate.baseline_kind = "model"
		candidate.baseline_records = loaded.records
		candidate.records = loaded.records
		candidate.round_id = manifest.round_id
		candidate.model_revision = manifest.model_revision
		candidate.session_id = (snapshot.session_id + "|" + manifest.round_id + "|" + loaded.sha256).sha256_text()
		candidate.revision = 0
		candidate.review_state = {}
		candidate.batch_operations = []
		candidate.explicit_frames = []
		for record in loaded.records: candidate.explicit_frames.append(int(record.frame))
		store = STORE.new()
		errors = store.load_model_records(loaded.records)
		if errors.is_empty(): errors = store.configure_session(candidate)
		if errors.is_empty(): errors = store.restore_corrected(candidate.records,candidate.review_state,candidate.batch_operations)
		if not errors.is_empty():
			return _failure("Invalid complete model coverage/source/time: " + "; ".join(errors))
		candidate = store.freeze_snapshot()
		errors = PACKAGE.validate_snapshot(candidate)
		if not errors.is_empty(): return _failure("Invalid candidate: " + "; ".join(errors))
	if PACKAGE.cancelled(token): return _failure("Round operation cancelled")
	return {"success":true,"errors":[],"snapshot":candidate,"store":store,"input_path":input_path,"input_sha256":loaded.sha256 if binding else input_sha,"annotation_sha256":loaded.sha256,"parent_sha256":parent_sha,"active_sha256":read.sha256,"candidate_sha256":_snapshot_digest(candidate),"operation":"binding" if binding else "round","path":path}

static func _commit(context: Dictionary, prepared: Dictionary, binding: bool, token) -> Dictionary:
	if not prepared.get("success",false) or prepared.get("operation") != ("binding" if binding else "round"):
		return _failure("Expected a successfully prepared candidate")
	# Revalidate all inputs at commit. Never trust a staged Store or mutable metadata.
	var fresh = _prepare(context,String(prepared.get("input_path","")),binding,token)
	if not fresh.success: return fresh
	if binding:
		return _commit_prepared_binding(
			context,
			prepared,
			fresh,
			token,
			["path","input_sha256","annotation_sha256","parent_sha256","active_sha256","candidate_sha256"],
		)
	for field in ["path","input_sha256","annotation_sha256","parent_sha256","active_sha256","candidate_sha256"]:
		if fresh[field] != prepared.get(field): return _failure("Prepared candidate changed before commit: " + field)
	if not prepared.get("snapshot") is Dictionary or _snapshot_digest(prepared.snapshot) != fresh.candidate_sha256:
		return _failure("Prepared snapshot changed before commit")
	var archive = ""
	var document = DOCUMENT.new()
	if not binding:
		var directory = fresh.path.get_base_dir().path_join("rounds")
		var errors = PACKAGE.prepare_output_parent(ProjectSettings.globalize_path(directory))
		if not errors.is_empty(): return _failure("Cannot archive old round: " + "; ".join(errors))
		archive = directory.path_join(fresh.active_sha256 + ".json")
		if document._is_link(archive): return _failure("Round archive path is occupied by a symbolic link")
		var error = document._preserve_original(fresh.path,archive,fresh.active_sha256,token)
		if not error.is_empty(): return _failure("Cannot archive old round: " + error)
		var prior = document.read_document(archive)
		if not prior.success or not CODEC.new().decode(prior.get("payload",{})).errors.is_empty():
			return _failure("Archived prior round failed validation")
	var saved = REPO.new().save_snapshot(fresh.snapshot,context.save_options,token)
	if not saved.success: return saved
	return {"success":true,"errors":[],"path":saved.path,"disk_sha256":saved.sha256,"sha256":saved.sha256,"snapshot":fresh.snapshot,"store":fresh.store,"session_id":fresh.snapshot.session_id,"revision":fresh.snapshot.revision,"needs_save":false,"backup_existing":false,"archive_path":archive}

static func _prepare_binding_candidate(snapshot: Dictionary, records: Array, kind: String, token) -> Dictionary:
	var candidate = snapshot.duplicate(true)
	candidate.baseline_kind = kind
	candidate.baseline_records = records
	candidate.revision = int(snapshot.revision) + 1
	# Implicit unknown display empties were never annotation evidence. Bind them
	# to original predictions while preserving only explicit human corrections.
	var corrected = PACKAGE.DIFF.records_by_frame(snapshot.records)
	candidate.records = []
	for record in records:
		candidate.records.append(corrected[int(record.frame)] if int(record.frame) in snapshot.explicit_frames else record)
	var store = STORE.new()
	var errors = store.load_model_records(records)
	if errors.is_empty(): errors = store.configure_session(candidate)
	if errors.is_empty(): errors = store.restore_corrected(candidate.records,candidate.review_state,candidate.batch_operations)
	if not errors.is_empty():
		return _failure("Baseline binding requires identical source/frame and optional timestamp presence in original and corrected records: " + "; ".join(errors))
	candidate = store.freeze_snapshot()
	errors = PACKAGE.validate_snapshot(candidate,token)
	if not errors.is_empty(): return _failure("Invalid candidate: " + "; ".join(errors))
	return {"success":true,"errors":[],"snapshot":candidate,"store":store}

static func _commit_prepared_binding(context: Dictionary, prepared: Dictionary, fresh: Dictionary, token, fields: Array) -> Dictionary:
	for field: String in fields:
		if not PACKAGE.DIFF.equivalent(fresh.get(field),prepared.get(field)):
			return _failure("Prepared candidate changed before commit: " + field)
	if not prepared.get("snapshot") is Dictionary or _snapshot_digest(prepared.snapshot) != fresh.candidate_sha256:
		return _failure("Prepared snapshot changed before commit")
	var saved = REPO.new().save_snapshot(fresh.snapshot,context.save_options,token)
	if not saved.success: return saved
	return {"success":true,"errors":[],"path":saved.path,"disk_sha256":saved.sha256,"sha256":saved.sha256,"snapshot":fresh.snapshot,"store":fresh.store,"session_id":fresh.snapshot.session_id,"revision":fresh.snapshot.revision,"needs_save":false,"backup_existing":false,"archive_path":""}

static func _read_records(path: String) -> Dictionary:
	var document = DOCUMENT.new()
	if document._is_link(path) or document._has_link_ancestor(path.get_base_dir()): return _failure("Model annotation path must not traverse symbolic links")
	var file = FileAccess.open(path,FileAccess.READ)
	if file == null: return _failure("Cannot read model annotations: " + path)
	var bytes = file.get_buffer(file.get_length())
	var error = file.get_error()
	file.close()
	if error != OK: return _failure("Cannot read complete model annotation bytes")
	var decoded = document.decode_utf8(bytes,path)
	if not decoded.success: return decoded
	var records = []
	var validator = VALIDATOR.new()
	var line_number = 0
	for line in decoded.text.split("\n"):
		line_number += 1
		if line.strip_edges().is_empty(): continue
		var parser = EXACT_JSON.new()
		if parser.parse(line) != OK: return _failure("Invalid model JSON at line %d" % line_number)
		var errors = validator.validate_record(parser.data)
		if not errors.is_empty(): return _failure("Model line %d: %s" % [line_number,"; ".join(errors)])
		records.append(parser.data)
	if records.is_empty(): return _failure("Model annotations require complete nonempty frame coverage")
	return {"success":true,"errors":[],"records":records,"bytes":bytes.size(),"sha256":document._digest(bytes)}

static func _media(snapshot: Dictionary) -> Dictionary:
	var media = {}
	for field in ["media_id","media_type","source","source_relative_path","source_sha256"]: media[field] = snapshot[field]
	return media

static func _snapshot_digest(snapshot: Dictionary) -> String:
	return JSON.stringify(PACKAGE.normalize(CODEC.new().encode(snapshot)),"",true,true).sha256_text()

static func _failure(message: String) -> Dictionary:
	return {"success":false,"errors":[message]}
