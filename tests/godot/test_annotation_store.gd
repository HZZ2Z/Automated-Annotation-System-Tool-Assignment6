extends RefCounted


const STORE_PATH := "res://client/domain/annotation_store.gd"
const COMMAND_PATH := "res://client/domain/command.gd"
const HISTORY_PATH := "res://client/domain/command_history.gd"
const MODEL_OUTPUT_VALIDATOR := preload("res://client/domain/model_output_validator.gd")


class ChangeClassCommand extends RefCounted:
	var frame: int
	var class_label: String
	var previous: Dictionary = {}
	var should_fail: bool
	var apply_count := 0

	func _init(next_frame: int, next_class_label: String, fail: bool = false) -> void:
		frame = next_frame
		class_label = next_class_label
		should_fail = fail

	func apply(store) -> PackedStringArray:
		if should_fail:
			return PackedStringArray(["test command failed"])
		var record: Dictionary = store.get_corrected_record(frame)
		if record.is_empty():
			return PackedStringArray(["frame does not exist"])
		previous = record.duplicate(true)
		record["regions"][0]["class"] = class_label
		var errors: PackedStringArray = store.replace_corrected_record(frame, record)
		if errors.is_empty():
			apply_count += 1
		return errors

	func revert(store) -> void:
		if not previous.is_empty():
			store.replace_corrected_record(frame, previous)


class ApplyOnlyCommand extends RefCounted:
	var apply_called := false

	func apply(_store) -> PackedStringArray:
		apply_called = true
		return PackedStringArray()


static func run(support: TestSupport) -> void:
	var store_script := ResourceLoader.load(STORE_PATH)
	var command_script := ResourceLoader.load(COMMAND_PATH)
	var history_script := ResourceLoader.load(HISTORY_PATH)
	support.expect(store_script != null, "AnnotationStore script should exist")
	support.expect(command_script != null, "EditCommand script should exist")
	support.expect(history_script != null, "CommandHistory script should exist")
	if store_script == null or command_script == null or history_script == null:
		return
	_test_load_and_public_read_immutability(store_script, support)
	_test_transactional_load(store_script, support)
	_test_transactional_replace_and_dirty_frames(store_script, support)
	_test_snapshot_and_digest(store_script, support)
	_test_command_base(command_script, store_script, support)
	_test_history_requires_reversible_commands(history_script, store_script, support)
	_test_history_execute_undo_redo(history_script, store_script, support)
	_test_history_failures_and_capacity(history_script, store_script, support)


static func _test_load_and_public_read_immutability(store_script, support: TestSupport) -> void:
	var store = store_script.new()
	var records := _two_records()
	support.expect(store.load_model_records(records).is_empty(), "valid model records should load")
	support.expect_equal(store.get_frame_count(), 2, "frame count should match loaded records")
	support.expect_equal(store.get_model_record(999), {}, "missing model frame should return an empty dictionary")
	support.expect_equal(store.get_corrected_record(999), {}, "missing corrected frame should return an empty dictionary")

	var model_read: Dictionary = store.get_model_record(0)
	model_read["source"] = "mutated"
	model_read["regions"][0]["box"][0] = 500
	support.expect_equal(store.get_model_record(0)["source"], "sample_v1", "model getter should return a deep copy")
	support.expect_equal(store.get_model_record(0)["regions"][0]["box"][0], 10, "model nested geometry should be deeply immutable")

	var corrected_read: Dictionary = store.get_corrected_record(0)
	corrected_read["regions"][0]["box"][1] = 300
	support.expect_equal(store.get_corrected_record(0)["regions"][0]["box"][1], 20, "corrected getter should return a deep copy")

	records[0]["source"] = "external mutation"
	records[0]["regions"][0]["box"][0] = 99
	support.expect_equal(store.get_model_record(0)["source"], "sample_v1", "load should deep-copy caller records")
	support.expect_equal(store.get_model_record(0)["regions"][0]["box"][0], 10, "load should deep-copy nested caller values")


static func _test_transactional_load(store_script, support: TestSupport) -> void:
	var store = store_script.new()
	support.expect(store.load_model_records(_two_records()).is_empty(), "initial model load should succeed")
	var before_model: Dictionary = store.get_model_record(0)
	var before_corrected: Dictionary = store.get_corrected_record(0)

	var invalid := _two_records()
	invalid[1]["regions"][0].erase("class")
	var invalid_errors: PackedStringArray = store.load_model_records(invalid)
	support.expect(not invalid_errors.is_empty(), "invalid record should reject entire load")
	support.expect_equal(store.get_model_record(0), before_model, "failed validation load should preserve model state")
	support.expect_equal(store.get_corrected_record(0), before_corrected, "failed validation load should preserve corrected state")

	var duplicate := _two_records()
	duplicate[1]["frame"] = 0
	var duplicate_errors: PackedStringArray = store.load_model_records(duplicate)
	support.expect(not duplicate_errors.is_empty(), "duplicate frame should reject entire load")
	support.expect(_contains_path_prefix(duplicate_errors, "records.1.frame"), "duplicate frame error should identify records.1.frame")
	support.expect_equal(store.get_frame_count(), 2, "duplicate frame load should preserve frame count")
	support.expect_equal(store.get_model_record(0), before_model, "duplicate frame load should preserve model state")

	var contaminated := _two_records()
	contaminated[0]["dataset_id"] = "project-only"
	var source_errors: PackedStringArray = store.load_model_records(contaminated)
	support.expect(not source_errors.is_empty(), "model load should reject project-only fields")
	support.expect(_contains_path_prefix(source_errors, "records.0.dataset_id"), "extra-field error should include indexed path")
	support.expect_equal(store.get_model_record(0), before_model, "contaminated load should preserve prior model state")


static func _test_transactional_replace_and_dirty_frames(store_script, support: TestSupport) -> void:
	var store = store_script.new()
	store.load_model_records(_two_records())
	var original_model: Dictionary = store.get_model_record(0)
	var replacement: Dictionary = store.get_corrected_record(0)
	replacement["regions"][0]["class"] = "reviewed_grasper"
	replacement["regions"][0]["filled"] = true
	support.expect(store.replace_corrected_record(0, replacement).is_empty(), "known UI-only fill state should not contaminate model validation")
	support.expect_equal(store.get_corrected_record(0)["regions"][0]["class"], "reviewed_grasper", "replacement should update corrected state")
	support.expect_equal(store.get_model_record(0), original_model, "replacement should never modify model state")
	var snapshot: Array = store.snapshot_corrected()
	support.expect_equal(snapshot[0].get("source"), "sample_v1", "corrected snapshot preserves frame source")
	support.expect(not snapshot[0]["regions"][0].has("filled"), "canonical snapshot strips UI-only fill state")
	support.expect(MODEL_OUTPUT_VALIDATOR.new().validate_record(snapshot[0]).is_empty(), "canonical snapshot must satisfy model-output shape")

	var invalid: Dictionary = store.get_corrected_record(0)
	invalid["regions"][0]["box"][2] = -1
	var before_invalid: Dictionary = store.get_corrected_record(0)
	support.expect(not store.replace_corrected_record(0, invalid).is_empty(), "schema-invalid replacement should be rejected")
	support.expect_equal(store.get_corrected_record(0), before_invalid, "invalid replacement should not mutate corrected state")

	var mismatch: Dictionary = store.get_corrected_record(0)
	mismatch["frame"] = 2
	var mismatch_errors: PackedStringArray = store.replace_corrected_record(0, mismatch)
	support.expect(not mismatch_errors.is_empty(), "replacement frame mismatch should be rejected")
	support.expect(_contains_path_prefix(mismatch_errors, "frame"), "frame mismatch error should identify frame")
	support.expect_equal(store.get_corrected_record(0), before_invalid, "frame mismatch should not mutate corrected state")

	var missing_record := _valid_box()
	missing_record["frame"] = 5
	var missing_errors: PackedStringArray = store.replace_corrected_record(5, missing_record)
	support.expect(not missing_errors.is_empty(), "replacement should reject a frame absent from the store")
	support.expect_equal(store.get_frame_count(), 2, "missing-frame replacement should not insert a frame")

	var frame_two: Dictionary = store.get_corrected_record(2)
	frame_two["regions"][0]["class"] = "frame-two-edit"
	store.replace_corrected_record(2, frame_two)
	var dirty: PackedInt64Array = store.get_dirty_frames()
	support.expect_equal(dirty.size(), 2, "two replacements should mark two dirty frames")
	if dirty.size() == 2:
		support.expect_equal(dirty[0], 0, "dirty frames should be sorted ascending")
		support.expect_equal(dirty[1], 2, "dirty frames should be sorted ascending")
	store.clear_dirty()
	support.expect(store.get_dirty_frames().is_empty(), "clear_dirty should remove all dirty frames")


static func _test_snapshot_and_digest(store_script, support: TestSupport) -> void:
	var records := _two_records()
	var store = store_script.new()
	store.load_model_records([records[1], records[0]])
	var digest_before: String = store.model_digest()
	support.expect(not digest_before.is_empty(), "model digest should be non-empty")

	var other_store = store_script.new()
	other_store.load_model_records([records[0], records[1]])
	support.expect_equal(other_store.model_digest(), digest_before, "model digest should be stable across input ordering")

	var replacement: Dictionary = store.get_corrected_record(0)
	replacement["regions"][0]["class"] = "edited"
	store.replace_corrected_record(0, replacement)
	support.expect_equal(store.model_digest(), digest_before, "corrected edits should not change model digest")
	var model_copy: Dictionary = store.get_model_record(0)
	model_copy["source"] = "external"
	support.expect_equal(store.model_digest(), digest_before, "mutating model getter copy should not change digest")

	var snapshot: Array = store.snapshot_corrected()
	support.expect_equal(snapshot.size(), 2, "snapshot should include every frame")
	if snapshot.size() == 2:
		support.expect_equal(snapshot[0]["frame"], 0, "snapshot should be sorted by frame")
		support.expect_equal(snapshot[1]["frame"], 2, "snapshot should be sorted by frame")
		for record in snapshot:
			support.expect_equal(record["source"], "sample_v1", "snapshot records should preserve frame source")
	support.expect_equal(store.get_model_record(0)["source"], "sample_v1", "snapshot should not alter model source")
	snapshot[0]["source"] = "snapshot mutation"
	snapshot[0]["regions"][0]["box"][0] = 400
	support.expect_equal(store.get_corrected_record(0)["regions"][0]["class"], "edited", "snapshot should return copied records")
	support.expect_equal(store.get_corrected_record(0)["regions"][0]["box"][0], 10, "snapshot nested values should be copied")


static func _test_command_base(command_script, store_script, support: TestSupport) -> void:
	var store = store_script.new()
	store.load_model_records(_two_records())
	var command = command_script.new()
	support.expect(not command.apply(store).is_empty(), "base edit command should report unimplemented apply")
	command.revert(store)


static func _test_history_requires_reversible_commands(history_script, store_script, support: TestSupport) -> void:
	var store = store_script.new()
	store.load_model_records(_two_records())
	var history = history_script.new()
	var before: Dictionary = store.get_corrected_record(0)
	var apply_only := ApplyOnlyCommand.new()
	var apply_only_errors: PackedStringArray = history.execute(apply_only, store)
	support.expect(not apply_only_errors.is_empty(), "apply-only command should be rejected")
	support.expect(" ".join(apply_only_errors).contains("revert"), "apply-only rejection should clearly require revert(store)")
	support.expect(not apply_only.apply_called, "rejected apply-only command should not be applied")
	support.expect_equal(store.get_corrected_record(0), before, "rejected apply-only command should not mutate the store")
	support.expect_equal(history.get_undo_count(), 0, "rejected apply-only command should not enter undo history")
	support.expect_equal(history.get_redo_count(), 0, "rejected apply-only command should not alter redo history")

	for malformed in [null, 42, "command", {}]:
		var errors: PackedStringArray = history.execute(malformed, store)
		support.expect(not errors.is_empty(), "null and non-object commands should return a clear error")
	support.expect_equal(store.get_corrected_record(0), before, "malformed commands should not mutate the store")
	support.expect_equal(history.get_undo_count(), 0, "malformed commands should not alter undo history")
	support.expect_equal(history.get_redo_count(), 0, "malformed commands should not alter redo history")


static func _test_history_execute_undo_redo(history_script, store_script, support: TestSupport) -> void:
	var store = store_script.new()
	store.load_model_records(_two_records())
	var history = history_script.new()
	support.expect_equal(history.get_undo_count(), 0, "new history should have no undo entries")
	support.expect_equal(history.get_redo_count(), 0, "new history should have no redo entries")
	support.expect(not history.can_undo(), "new history should not allow undo")
	support.expect(not history.can_redo(), "new history should not allow redo")

	var command := ChangeClassCommand.new(0, "after-apply")
	support.expect(history.execute(command, store).is_empty(), "successful command should execute")
	support.expect_equal(store.get_corrected_record(0)["regions"][0]["class"], "after-apply", "execute should apply command")
	support.expect_equal(history.get_undo_count(), 1, "successful command should enter undo history")
	support.expect(history.can_undo(), "successful command should enable undo")

	support.expect(history.undo(store), "undo should succeed when an entry exists")
	support.expect_equal(store.get_corrected_record(0)["regions"][0]["class"], "grasper", "undo should revert command")
	support.expect_equal(history.get_redo_count(), 1, "undo should move command to redo history")
	support.expect(history.redo(store).is_empty(), "redo should re-apply command")
	support.expect_equal(store.get_corrected_record(0)["regions"][0]["class"], "after-apply", "redo should apply command again")
	support.expect_equal(command.apply_count, 2, "redo should call apply a second time")

	history.undo(store)
	var replacement := ChangeClassCommand.new(0, "new-branch")
	history.execute(replacement, store)
	support.expect_equal(history.get_redo_count(), 0, "successful new command should clear redo history")
	support.expect(not history.can_redo(), "cleared redo history should not allow redo")


static func _test_history_failures_and_capacity(history_script, store_script, support: TestSupport) -> void:
	var store = store_script.new()
	store.load_model_records(_two_records())
	var history = history_script.new(2)
	var first := ChangeClassCommand.new(0, "one")
	history.execute(first, store)
	history.undo(store)
	var before_failure: Dictionary = store.get_corrected_record(0)
	var failed := ChangeClassCommand.new(0, "never", true)
	support.expect(not history.execute(failed, store).is_empty(), "failed apply should return its errors")
	support.expect_equal(store.get_corrected_record(0), before_failure, "failed test command should leave store unchanged")
	support.expect_equal(history.get_undo_count(), 0, "failed apply should not enter undo history")
	support.expect_equal(history.get_redo_count(), 1, "failed apply should not clear redo history")

	for value in ["two", "three", "four"]:
		history.execute(ChangeClassCommand.new(0, value), store)
	support.expect_equal(history.get_undo_count(), 2, "custom history capacity should drop oldest undo entry")
	history.undo(store)
	history.undo(store)
	support.expect(not history.can_undo(), "only retained capacity entries should be undoable")
	support.expect_equal(store.get_corrected_record(0)["regions"][0]["class"], "two", "dropping oldest entry should retain state before kept commands")

	var default_store = store_script.new()
	default_store.load_model_records(_two_records())
	var default_history = history_script.new()
	for index in range(201):
		default_history.execute(ChangeClassCommand.new(0, "value-%d" % index), default_store)
	support.expect_equal(default_history.get_undo_count(), 200, "default history capacity should be 200")
	for index in range(200):
		default_history.undo(default_store)
	support.expect_equal(default_store.get_corrected_record(0)["regions"][0]["class"], "value-0", "default capacity should discard only the oldest command")

	var clamped_history = history_script.new(0)
	clamped_history.execute(ChangeClassCommand.new(0, "positive-capacity"), default_store)
	support.expect_equal(clamped_history.get_undo_count(), 1, "non-positive requested capacity should still yield positive capacity")


static func _contains_path_prefix(errors: PackedStringArray, path: String) -> bool:
	for error in errors:
		if error.begins_with("%s:" % path):
			return true
	return false


static func _two_records() -> Array:
	var first := _valid_box()
	var second := _valid_box()
	second["frame"] = 2
	second["regions"][0]["id"] = "fixture-r2"
	return [first, second]


static func _valid_box() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://core/fixtures/valid/model-output-v1-box-only.json"))
