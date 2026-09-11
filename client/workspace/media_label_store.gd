class_name MediaLabelStore
extends RefCounted

signal saved(path: String)
signal save_failed(frame_ids: PackedInt64Array, path: String, message: String)

const REPOSITORY := preload("res://client/workspace/session_repository.gd")
const PATHS := preload("res://client/workspace/workspace_paths.gd")

var _store: Variant
var _path := ""
var _disk_sha256 := ""
var _saved_revision := -1
var _backup_existing := false
var _needs_save := false
var _opened_context: Dictionary = {}
var _baseline_descriptor: Dictionary = {}

## Synchronous adapter for workers and offline callers. UI uses BackgroundJob.
func prepare(workspace_root: String, media_entry: Dictionary, frame_entries: Array, seed_records: Variant = [], context: Dictionary = {}) -> PackedStringArray:
	var root := ProjectSettings.globalize_path(workspace_root).simplify_path().trim_suffix("/")
	var label_root := ProjectSettings.globalize_path(String(media_entry.get("label_root",root))).simplify_path().trim_suffix("/")
	if not DirAccess.dir_exists_absolute(root) or not DirAccess.dir_exists_absolute(label_root): return PackedStringArray(["Workspace and label roots must exist"])
	if label_root != root and not label_root.begins_with(root + "/"): return PackedStringArray(["Label root must remain inside the workspace"])
	if not PATHS.is_portable_media_id(String(media_entry.get("media_id",""))): return PackedStringArray(["Invalid media identity"])
	var options := context.duplicate(true)
	options["path"] = PATHS.label_path(label_root, media_entry.media_id)
	options["media_id"] = media_entry.media_id
	options["media_type"] = media_entry.get("media_type")
	options["source_relative_path"] = media_entry.get("source_relative_path",media_entry.get("relative_path"))
	options["source_sha256"] = media_entry.get("source_sha256")
	options["source"] = context.get("source",media_entry.media_id)
	options["frame_entries"] = frame_entries.duplicate(true)
	for index in range(options.frame_entries.size()):
		if options.frame_entries[index] is Dictionary:
			if not options.frame_entries[index].has("frame_id"): options.frame_entries[index]["frame_id"] = options.frame_entries[index].get("frame")
			options.frame_entries[index]["frame"] = index
	if not seed_records is Array and not seed_records is Dictionary: return PackedStringArray(["Seed records must be an Array or Dictionary"])
	options["seed_records"] = seed_records if seed_records is Array else seed_records.values()
	options["baseline_kind"] = context.get("baseline_kind", "empty" if options.seed_records.is_empty() else "imported_labels")
	var result: Dictionary = REPOSITORY.new().open_session(options)
	if not result.success: return PackedStringArray(result.errors)
	adopt_session(result)
	return PackedStringArray()

## Adopt only after the opening worker has finished; ownership moves to main.
func adopt_session(result: Dictionary) -> void:
	_opened_context = result.snapshot.duplicate()
	for field: String in ["baseline_records", "records", "review_state", "batch_operations"]:
		_opened_context.erase(field)
	_store = result.store
	_path = result.path
	_disk_sha256 = result.disk_sha256
	_backup_existing = result.backup_existing
	_needs_save = result.needs_save
	_saved_revision = -1 if _needs_save else _store.current_revision()

func prepared_store() -> Variant: return _store

func set_baseline_descriptor(descriptor: Dictionary) -> void:
	_baseline_descriptor = descriptor.duplicate(true)

func baseline_descriptor() -> Dictionary:
	return _baseline_descriptor.duplicate(true)

func bind_store(store: Variant) -> PackedStringArray:
	if store != _store:
		var snapshot: Dictionary = store.freeze_snapshot()
		if not snapshot.has("session_id"):
			var errors: PackedStringArray = store.configure_session(_opened_context)
			if not errors.is_empty(): return errors
		_store = store
	return PackedStringArray()

func save_options() -> Dictionary:
	return {"path":_path,"expected_sha256":_disk_sha256,"backup_existing":_backup_existing}

func saved_revision() -> int: return _saved_revision
func label_path() -> String: return _path
func has_pending_changes() -> bool: return _store != null and (_needs_save or _store.current_revision() > _saved_revision)

func accept_saved(result: Dictionary) -> void:
	_disk_sha256 = result.sha256
	_saved_revision = int(result.revision)
	_backup_existing = false
	_needs_save = false
	saved.emit(_path)

func record_for_frame(frame_id: int) -> Dictionary:
	return _store.get_corrected_record(frame_id) if _store != null else {}

func all_display_records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _store != null: result.assign(_store.snapshot_corrected())
	return result

func replace_record(frame_id: int, record: Variant) -> PackedStringArray:
	return _store.replace_corrected_record(frame_id, record)

func is_explicit(frame_id: int) -> bool:
	return frame_id in _store.freeze_snapshot().explicit_frames if _store != null else false

func dirty_frame_ids() -> PackedInt64Array:
	return _store.get_dirty_frames() if _store != null else PackedInt64Array()

func workflow_state() -> Dictionary:
	return {"review_state":_store.snapshot_review_state(),"batch_operations":_store.snapshot_batch_operations()}

func replace_workflow_state(review_state: Variant, batch_operations: Variant) -> PackedStringArray:
	return _store.load_workflow_state(review_state,batch_operations)

## Compatibility boundary for command-line/offline consumers, never called by UI.
func flush() -> PackedStringArray:
	if not has_pending_changes(): return PackedStringArray()
	var result: Dictionary = REPOSITORY.new().save_snapshot(_store.freeze_snapshot(),save_options())
	if result.success:
		accept_saved(result)
		return PackedStringArray()
	var errors := PackedStringArray(result.errors)
	save_failed.emit(dirty_frame_ids(),_path,errors[0])
	return errors

func clear() -> void:
	_store = null
	_opened_context = {}
	_baseline_descriptor = {}
	_path = ""
	_disk_sha256 = ""
	_saved_revision = -1
	_backup_existing = false
	_needs_save = false
