extends RefCounted


const STORE_PATH := "res://client/domain/annotation_store.gd"
const HISTORY_PATH := "res://client/domain/command_history.gd"
const EDIT_PLUGIN := preload("res://client/plugins/edit/basic_edit_tools/plugin.gd")
const COMMAND_PATHS := {
	"move": "res://client/domain/commands/move_region_command.gd",
	"resize": "res://client/domain/commands/resize_box_command.gd",
	"add": "res://client/domain/commands/add_box_command.gd",
	"delete": "res://client/domain/commands/delete_region_command.gd",
	"relabel": "res://client/domain/commands/relabel_region_command.gd",
	"track": "res://client/domain/commands/set_track_id_command.gd",
	"fill": "res://client/domain/commands/toggle_fill_command.gd",
}


static func run(support: TestSupport) -> void:
	var scripts := {}
	for command_name: String in COMMAND_PATHS:
		var script: Script = ResourceLoader.load(COMMAND_PATHS[command_name])
		support.expect(script != null, "%s edit command should load" % command_name)
		if script != null:
			scripts[command_name] = script
	if scripts.size() != COMMAND_PATHS.size():
		return
	_test_round_trips(scripts, support)
	_test_invalid_commands_do_not_enter_history(scripts, support)
	_test_retained_inputs_are_snapshots(scripts, support)
	_test_add_ids_are_unique_and_monotonic(scripts, support)
	_test_history_regressions_with_real_commands(scripts, support)
	_test_noop_command_preserves_history_and_dirty_state(scripts, support)
	_test_invalid_real_commands_preserve_redo_branch(scripts, support)
	_test_add_id_collision_and_cross_frame_monotonicity(scripts, support)
	_test_relabel_updates_known_kind_and_preserves_unknown_kind(scripts, support)
	_test_hybrid_geometry_uses_polygon_for_hit_and_move(scripts, support)
	_test_image_bounds_are_atomic_and_round_trip(scripts, support)


static func _test_round_trips(scripts: Dictionary, support: TestSupport) -> void:
	var cases := [
		{"name": "move box", "script": scripts.move, "args": [0, _record(), "box-1", Vector2(3, 4)], "check": func(record): return record.regions[0].box == [13.0, 14.0, 20, 15]},
		{"name": "move polygon", "script": scripts.move, "args": [0, _record(), "poly-1", Vector2(2, 3)], "check": func(record): return record.regions[1].polygon == [[42.0, 43.0], [57.0, 43.0], [47.0, 58.0]]},
		{"name": "resize box", "script": scripts.resize, "args": [0, _record(), "box-1", [10, 10, 28, 24]], "check": func(record): return record.regions[0].box == [10, 10, 28, 24]},
		{"name": "add box", "script": scripts.add, "args": [0, _record(), [70, 60, 12, 9], "scissors", "instrument"], "check": func(record): return record.regions.size() == 3 and record.regions[2]["class"] == "scissors" and not record.regions[2].has("filled")},
		{"name": "delete region", "script": scripts.delete, "args": [0, _record(), "box-1"], "check": func(record): return record.regions.size() == 1 and record.regions[0].id == "poly-1"},
		{"name": "relabel region", "script": scripts.relabel, "args": [0, _record(), "box-1", "scissors"], "check": func(record): return record.regions[0]["class"] == "scissors"},
		{"name": "set track ID", "script": scripts.track, "args": [0, _record(), "box-1", "T99"], "check": func(record): return record.regions[0].track_id == "T99"},
		{"name": "clear track ID", "script": scripts.track, "args": [0, _record(), "box-1", null], "check": func(record): return record.regions[0].track_id == null},
		{"name": "toggle default-visible fill", "script": scripts.fill, "args": [0, _record(), "box-1"], "check": func(record): return record.regions[0].filled == false},
	]
	for case: Dictionary in cases:
		var store = _store()
		var history = _history()
		var before: Dictionary = store.get_corrected_record(0)
		var model_before: Dictionary = store.get_model_record(0)
		var command = case.script.new.callv(case.args)
		var errors: PackedStringArray = history.execute(command, store)
		support.expect(errors.is_empty(), "%s should apply" % case.name)
		var after: Dictionary = store.get_corrected_record(0)
		support.expect(case.check.call(after), "%s should make its requested change" % case.name)
		support.expect(history.undo(store), "%s should undo" % case.name)
		support.expect_equal(store.get_corrected_record(0), before, "%s undo should restore the exact snapshot" % case.name)
		support.expect(history.redo(store).is_empty(), "%s should redo" % case.name)
		support.expect(case.check.call(store.get_corrected_record(0)), "%s redo should restore the changed snapshot" % case.name)
		support.expect_equal(store.get_model_record(0), model_before, "%s must leave model output immutable" % case.name)


static func _test_invalid_commands_do_not_enter_history(scripts: Dictionary, support: TestSupport) -> void:
	var invalid_cases := [
		{"name": "zero width", "command": scripts.resize.new(0, _record(), "box-1", [10, 10, 0, 15])},
		{"name": "out of bounds", "command": scripts.move.new(0, _record(), "box-1", Vector2(-11, 0))},
		{"name": "missing region", "command": scripts.delete.new(0, _record(), "missing")},
		{"name": "empty class", "command": scripts.relabel.new(0, _record(), "box-1", "")},
		{"name": "non-string class", "command": scripts.relabel.new(0, _record(), "box-1", 12)},
		{"name": "empty track ID", "command": scripts.track.new(0, _record(), "box-1", "")},
		{"name": "non-string track ID", "command": scripts.track.new(0, _record(), "box-1", 12)},
		{"name": "polygon resize", "command": scripts.resize.new(0, _record(), "poly-1", [40, 40, 10, 10])},
	]
	for case: Dictionary in invalid_cases:
		var store = _store()
		var history = _history()
		var before: Dictionary = store.get_corrected_record(0)
		var errors: PackedStringArray = history.execute(case.command, store)
		support.expect(not errors.is_empty(), "%s should be rejected clearly" % case.name)
		support.expect_equal(store.get_corrected_record(0), before, "%s should not mutate corrected state" % case.name)
		support.expect_equal(history.get_undo_count(), 0, "%s should not enter undo history" % case.name)
		support.expect_equal(history.get_redo_count(), 0, "%s should not alter redo history" % case.name)


static func _test_retained_inputs_are_snapshots(scripts: Dictionary, support: TestSupport) -> void:
	var record := _record()
	var requested_box := [1, 2, 30, 40]
	var command = scripts.resize.new(0, record, "box-1", requested_box)
	record.regions[0].box[0] = 99
	requested_box[0] = 88
	var store = _store()
	var history = _history()
	support.expect(history.execute(command, store).is_empty(), "command should use construction-time snapshots")
	support.expect_equal(store.get_corrected_record(0).regions[0].box, [1, 2, 30, 40], "retained record and geometry inputs should be deep-copied")


static func _test_add_ids_are_unique_and_monotonic(scripts: Dictionary, support: TestSupport) -> void:
	var store = _store()
	var history = _history()
	var first = scripts.add.new(0, store.get_corrected_record(0), [80, 70, 5, 5], "unknown", "region")
	support.expect(history.execute(first, store).is_empty(), "first added box should apply")
	var first_id: String = first.get_region_id()
	var delete = scripts.delete.new(0, store.get_corrected_record(0), first_id)
	support.expect(history.execute(delete, store).is_empty(), "added box should be deletable")
	var second = scripts.add.new(0, store.get_corrected_record(0), [90, 70, 5, 5], "unknown", "region")
	support.expect(history.execute(second, store).is_empty(), "second added box should apply")
	support.expect(not first_id.is_empty() and second.get_region_id() != first_id, "deleted generated IDs must not be reused in the session")
	var ids := {}
	for region: Dictionary in store.get_corrected_record(0).regions:
		ids[region.id] = true
	support.expect_equal(ids.size(), store.get_corrected_record(0).regions.size(), "generated ID must be unique within its frame")


static func _test_history_regressions_with_real_commands(scripts: Dictionary, support: TestSupport) -> void:
	var store = _store()
	var history = _history(2)
	for delta in [Vector2(1, 0), Vector2(2, 0), Vector2(3, 0)]:
		support.expect(history.execute(scripts.move.new(0, store.get_corrected_record(0), "box-1", delta), store).is_empty(), "capacity setup move should apply")
	support.expect_equal(history.get_undo_count(), 2, "real edit commands should retain bounded history behavior")
	support.expect(history.undo(store), "real edit command should undo before branch")
	support.expect_equal(history.get_redo_count(), 1, "undo should create a redo branch")
	support.expect(history.execute(scripts.relabel.new(0, store.get_corrected_record(0), "box-1", "unknown"), store).is_empty(), "new real edit should apply on branch")
	support.expect_equal(history.get_redo_count(), 0, "successful real edit should clear redo branch")


static func _test_noop_command_preserves_history_and_dirty_state(scripts: Dictionary, support: TestSupport) -> void:
	var store = _store()
	var history = _history()
	var real = scripts.move.new(0, store.get_corrected_record(0), "box-1", Vector2(1, 0))
	support.expect(history.execute(real, store).is_empty(), "no-op setup edit should apply")
	support.expect(history.undo(store), "no-op setup edit should create a redo branch")
	store.clear_dirty()
	var before: Dictionary = store.get_corrected_record(0)
	var noop = scripts.resize.new(0, before, "box-1", before.regions[0].box.duplicate(true))
	support.expect(history.execute(noop, store).is_empty(), "a valid no-op command should be accepted without applying")
	support.expect_equal(store.get_corrected_record(0), before, "a no-op command must preserve corrected state")
	support.expect_equal(store.get_dirty_frames(), PackedInt64Array(), "a no-op command must not mark the frame dirty")
	support.expect_equal(history.get_undo_count(), 0, "a no-op command must not enter undo history")
	support.expect_equal(history.get_redo_count(), 1, "a no-op command must preserve the existing redo branch")


static func _test_invalid_real_commands_preserve_redo_branch(scripts: Dictionary, support: TestSupport) -> void:
	var store = _store()
	var history = _history()
	history.execute(scripts.relabel.new(0, store.get_corrected_record(0), "box-1", "unknown"), store)
	history.undo(store)
	var before: Dictionary = store.get_corrected_record(0)
	var invalid_commands := [
		scripts.resize.new(0, before, "box-1", [10, 10, 0, 15]),
		scripts.resize.new(0, before, "box-1", [10, 10, NAN, 15]),
		scripts.resize.new(0, before, "box-1", [10, 10, INF, 15]),
		scripts.move.new(99, before, "box-1", Vector2(1, 0)),
		scripts.move.new(0, before, "missing", Vector2(1, 0)),
	]
	for command: Variant in invalid_commands:
		var errors: PackedStringArray = history.execute(command, store)
		support.expect(not errors.is_empty(), "invalid real command should return validation errors on an existing redo branch")
		support.expect_equal(store.get_corrected_record(0), before, "invalid real command should preserve corrected state on a redo branch")
		support.expect_equal(history.get_undo_count(), 0, "invalid real command should preserve undo count")
		support.expect_equal(history.get_redo_count(), 1, "invalid real command should preserve redo count")


static func _test_add_id_collision_and_cross_frame_monotonicity(scripts: Dictionary, support: TestSupport) -> void:
	var probe = scripts.add.new(0, _record(), [70, 60, 5, 5], "unknown", "region")
	var probe_id: String = probe.get_region_id()
	var number := int(probe_id.get_slice("-", probe_id.get_slice_count("-") - 1))
	var collision_id := "frame-0-added-%d" % (number + 1)
	var collision_record := _record()
	collision_record.regions.append({"id": collision_id, "class": "unknown", "kind": "region", "box": [80, 60, 5, 5], "track_id": null})
	var collision_store = load(STORE_PATH).new()
	collision_store.load_model_records([collision_record])
	var collision_history = _history()
	var collided = scripts.add.new(0, collision_store.get_corrected_record(0), [90, 60, 5, 5], "unknown", "region")
	support.expect(collision_history.execute(collided, collision_store).is_empty(), "add should skip a generated candidate already present in the frame")
	support.expect(collided.get_region_id() != collision_id, "generated ID collision should advance rather than duplicate the candidate")

	var frame_zero := _record()
	var frame_one := _record()
	frame_one.frame = 1
	frame_one.regions[0].id = "frame-one-box"
	frame_one.regions[1].id = "frame-one-poly"
	var store = load(STORE_PATH).new()
	store.load_model_records([frame_zero, frame_one])
	var history = _history()
	var added_zero = scripts.add.new(0, store.get_corrected_record(0), [70, 60, 5, 5], "unknown", "region")
	history.execute(added_zero, store)
	var zero_id: String = added_zero.get_region_id()
	var added_one = scripts.add.new(1, store.get_corrected_record(1), [70, 60, 5, 5], "unknown", "region")
	history.execute(added_one, store)
	var one_id: String = added_one.get_region_id()
	history.execute(scripts.delete.new(0, store.get_corrected_record(0), zero_id), store)
	var next_zero = scripts.add.new(0, store.get_corrected_record(0), [75, 60, 5, 5], "unknown", "region")
	history.execute(next_zero, store)
	support.expect(zero_id != one_id and next_zero.get_region_id() != zero_id and next_zero.get_region_id() != one_id, "generated IDs should remain session-monotonic across frames and deletion")


static func _test_relabel_updates_known_kind_and_preserves_unknown_kind(scripts: Dictionary, support: TestSupport) -> void:
	var store = _store()
	var history = _history()
	var before: Dictionary = store.get_corrected_record(0)
	var known = scripts.relabel.new(0, before, "box-1", "gallbladder")
	support.expect(history.execute(known, store).is_empty(), "known cross-kind relabel should apply atomically")
	var known_after: Dictionary = store.get_corrected_record(0)
	support.expect_equal(known_after.regions[0]["class"], "gallbladder", "known relabel should update class")
	support.expect_equal(known_after.regions[0]["kind"], "anatomy", "known relabel should update kind from shared taxonomy")
	support.expect(history.undo(store), "known cross-kind relabel should undo")
	support.expect_equal(store.get_corrected_record(0), before, "known cross-kind relabel undo should restore exact class and kind")
	support.expect(history.redo(store).is_empty(), "known cross-kind relabel should redo")
	support.expect_equal(store.get_corrected_record(0), known_after, "known cross-kind relabel redo should restore exact class and kind")

	var unknown_before: Dictionary = store.get_corrected_record(0)
	var free_text = scripts.relabel.new(0, unknown_before, "box-1", "reviewer_free_text")
	support.expect(history.execute(free_text, store).is_empty(), "unknown free-text relabel should apply")
	var free_text_after: Dictionary = store.get_corrected_record(0)
	support.expect_equal(free_text_after.regions[0]["class"], "reviewer_free_text", "unknown relabel should preserve text exactly")
	support.expect_equal(free_text_after.regions[0]["kind"], "anatomy", "unknown relabel should preserve the prior legal kind")
	support.expect(history.undo(store), "unknown free-text relabel should undo")
	support.expect_equal(store.get_corrected_record(0), unknown_before, "unknown free-text relabel undo should restore exact snapshot")
	support.expect(history.redo(store).is_empty(), "unknown free-text relabel should redo")
	support.expect_equal(store.get_corrected_record(0), free_text_after, "unknown free-text relabel redo should restore exact snapshot")


static func _test_hybrid_geometry_uses_polygon_for_hit_and_move(scripts: Dictionary, support: TestSupport) -> void:
	var record := _record()
	record["regions"] = [{
		"id": "hybrid",
		"class": "grasper",
		"kind": "instrument",
		"box": [0, 0, 100, 100],
		"polygon": [[10, 10], [30, 10], [30, 30], [10, 30]],
	}]
	var plugin = EDIT_PLUGIN.new()
	support.expect_equal(plugin.call("_hit_test", record, Vector2(20, 20)).get("id"), "hybrid", "Edit should hit the same canonical polygon as Render")
	support.expect_equal(plugin.call("_hit_test", record, Vector2(80, 80)), {}, "Edit should not fall through to the box when a valid polygon exists")
	var preview: Dictionary = record.duplicate(true)
	plugin.call("_apply_preview_move", preview, "hybrid", Vector2(3, 4))
	support.expect_equal(preview.regions[0].polygon, [[13.0, 14.0], [33.0, 14.0], [33.0, 34.0], [13.0, 34.0]], "drag preview should move the canonical polygon")
	support.expect_equal(preview.regions[0].box, [0, 0, 100, 100], "drag preview should leave the fallback box unchanged")
	var command = scripts.move.new(0, record, "hybrid", Vector2(3, 4))
	support.expect_equal(command.after.regions[0].polygon, preview.regions[0].polygon, "committed move should use the same polygon priority as its preview")
	support.expect_equal(command.after.regions[0].box, [0, 0, 100, 100], "committed move should leave the fallback box unchanged")
	var hybrid_store = load(STORE_PATH).new()
	support.expect(hybrid_store.load_model_records([record]).is_empty(), "a hybrid box/polygon region should remain valid Model Output V1")
	var resize_errors: PackedStringArray = _history().execute(scripts.resize.new(0, record, "hybrid", [0, 0, 120, 120]), hybrid_store)
	support.expect(not resize_errors.is_empty(), "box resize should reject a hybrid region whose canonical geometry is polygon")
	support.expect_equal(hybrid_store.get_corrected_record(0), record, "rejected fallback-box resize should preserve the hybrid record")


static func _test_image_bounds_are_atomic_and_round_trip(scripts: Dictionary, support: TestSupport) -> void:
	var image_size := Vector2(100, 80)
	var invalid_commands := [
		{"name": "move beyond right edge", "command": scripts.move.new(0, _record(), "box-1", Vector2(80, 0), image_size)},
		{"name": "resize beyond bottom edge", "command": scripts.resize.new(0, _record(), "box-1", [10, 10, 20, 71], image_size)},
		{"name": "add beyond right edge", "command": scripts.add.new(0, _record(), [95, 70, 6, 5], "unknown", "region", image_size)},
	]
	for case: Dictionary in invalid_commands:
		var store = _store()
		var history = _history()
		var before: Dictionary = store.get_corrected_record(0)
		var errors: PackedStringArray = history.execute(case.command, store)
		support.expect(not errors.is_empty(), "%s must explain its image-boundary refusal" % case.name)
		support.expect(_errors_contain(errors, "inside the current image"), "%s should identify the image boundary" % case.name)
		support.expect_equal(case.command.after, case.command.before, "%s should restore its retained after snapshot" % case.name)
		support.expect_equal(store.get_corrected_record(0), before, "%s must be atomic" % case.name)
		support.expect_equal(history.get_undo_count(), 0, "%s must not enter undo history" % case.name)

	var valid_store = _store()
	var valid_history = _history()
	var valid_before: Dictionary = valid_store.get_corrected_record(0)
	var boundary_move = scripts.move.new(0, valid_before, "box-1", Vector2(70, 55), image_size)
	support.expect(valid_history.execute(boundary_move, valid_store).is_empty(), "a move ending exactly on the image boundary should apply")
	var valid_after: Dictionary = valid_store.get_corrected_record(0)
	support.expect_equal(valid_after.regions[0].box, [80.0, 65.0, 20, 15], "boundary move should retain exact geometry")
	support.expect(valid_history.undo(valid_store), "a bounded move should undo")
	support.expect_equal(valid_store.get_corrected_record(0), valid_before, "bounded move undo should restore the exact snapshot")
	support.expect(valid_history.redo(valid_store).is_empty(), "a bounded move should redo")
	support.expect_equal(valid_store.get_corrected_record(0), valid_after, "bounded move redo should restore exact geometry")
	support.expect_equal(valid_history.get_undo_count(), 1, "bounded move redo should restore one undo entry")
	support.expect_equal(valid_history.get_redo_count(), 0, "bounded move redo should consume its redo entry")

	var add_store = _store()
	var add_history = _history()
	var add_before: Dictionary = add_store.get_corrected_record(0)
	var add_command = scripts.add.new(0, add_before, [70, 60, 30, 20], "unknown", "region", image_size)
	var added_id: String = add_command.get_region_id()
	var add_expected: Dictionary = add_before.duplicate(true)
	add_expected.regions.append({
		"id": added_id,
		"class": "unknown",
		"kind": "region",
		"box": [70, 60, 30, 20],
		"track_id": null,
	})
	support.expect(not added_id.is_empty(), "bounded Add Box should allocate a concrete region ID")
	support.expect(add_history.execute(add_command, add_store).is_empty(), "bounded Add Box should apply")
	support.expect_equal(add_store.get_corrected_record(0), add_expected, "bounded Add Box should produce the exact requested record")
	support.expect_equal(add_history.get_undo_count(), 1, "bounded Add Box should create one undo entry")
	support.expect_equal(add_history.get_redo_count(), 0, "bounded Add Box apply should have no redo entry")
	support.expect(add_history.undo(add_store), "bounded Add Box should undo")
	support.expect_equal(add_store.get_corrected_record(0), add_before, "bounded Add Box undo should restore the exact before record")
	support.expect_equal(add_history.get_undo_count(), 0, "bounded Add Box undo should consume its undo entry")
	support.expect_equal(add_history.get_redo_count(), 1, "bounded Add Box undo should create one redo entry")
	support.expect(add_history.redo(add_store).is_empty(), "bounded Add Box should redo")
	support.expect_equal(add_store.get_corrected_record(0), add_expected, "bounded Add Box redo should restore the exact after record")
	support.expect_equal(add_history.get_undo_count(), 1, "bounded Add Box redo should restore one undo entry")
	support.expect_equal(add_history.get_redo_count(), 0, "bounded Add Box redo should consume its redo entry")

	var resize_store = _store()
	var resize_history = _history()
	var resize_before: Dictionary = resize_store.get_corrected_record(0)
	var resize_expected: Dictionary = resize_before.duplicate(true)
	resize_expected.regions[0].box = [10, 10, 90, 70]
	var resize_command = scripts.resize.new(0, resize_before, "box-1", [10, 10, 90, 70], image_size)
	support.expect(resize_history.execute(resize_command, resize_store).is_empty(), "bounded box resize should apply")
	support.expect_equal(resize_store.get_corrected_record(0), resize_expected, "bounded box resize should produce the exact requested record")
	support.expect_equal(resize_history.get_undo_count(), 1, "bounded box resize should create one undo entry")
	support.expect_equal(resize_history.get_redo_count(), 0, "bounded box resize apply should have no redo entry")
	support.expect(resize_history.undo(resize_store), "bounded box resize should undo")
	support.expect_equal(resize_store.get_corrected_record(0), resize_before, "bounded box resize undo should restore the exact before record")
	support.expect_equal(resize_history.get_undo_count(), 0, "bounded box resize undo should consume its undo entry")
	support.expect_equal(resize_history.get_redo_count(), 1, "bounded box resize undo should create one redo entry")
	support.expect(resize_history.redo(resize_store).is_empty(), "bounded box resize should redo")
	support.expect_equal(resize_store.get_corrected_record(0), resize_expected, "bounded box resize redo should restore the exact after record")
	support.expect_equal(resize_history.get_undo_count(), 1, "bounded box resize redo should restore one undo entry")
	support.expect_equal(resize_history.get_redo_count(), 0, "bounded box resize redo should consume its redo entry")


static func _errors_contain(errors: PackedStringArray, fragment: String) -> bool:
	for error: String in errors:
		if fragment in error:
			return true
	return false


static func _store():
	var store = load(STORE_PATH).new()
	store.load_model_records([_record()])
	return store


static func _history(capacity: int = 200):
	return load(HISTORY_PATH).new(capacity)


static func _record() -> Dictionary:
	return {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"regions": [
			{"id": "box-1", "class": "grasper", "kind": "instrument", "box": [10, 10, 20, 15], "conf": 0.9, "track_id": "T01"},
			{"id": "poly-1", "class": "gallbladder", "kind": "anatomy", "polygon": [[40, 40], [55, 40], [45, 55]]},
		],
	}
