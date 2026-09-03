extends RefCounted


const STORE_PATH := "res://client/domain/annotation_store.gd"
const HISTORY_PATH := "res://client/domain/command_history.gd"
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


static func _test_round_trips(scripts: Dictionary, support: TestSupport) -> void:
	var cases := [
		{"name": "move box", "script": scripts.move, "args": [0, _record(), "box-1", Vector2(3, 4)], "check": func(record): return record.regions[0].box == [13.0, 14.0, 20, 15]},
		{"name": "move polygon", "script": scripts.move, "args": [0, _record(), "poly-1", Vector2(2, 3)], "check": func(record): return record.regions[1].polygon == [[42.0, 43.0], [57.0, 43.0], [47.0, 58.0]]},
		{"name": "resize box", "script": scripts.resize, "args": [0, _record(), "box-1", [10, 10, 28, 24]], "check": func(record): return record.regions[0].box == [10, 10, 28, 24]},
		{"name": "add box", "script": scripts.add, "args": [0, _record(), [70, 60, 12, 9], "scissors", "instrument"], "check": func(record): return record.regions.size() == 3 and record.regions[2]["class"] == "scissors"},
		{"name": "delete region", "script": scripts.delete, "args": [0, _record(), "box-1"], "check": func(record): return record.regions.size() == 1 and record.regions[0].id == "poly-1"},
		{"name": "relabel region", "script": scripts.relabel, "args": [0, _record(), "box-1", "scissors"], "check": func(record): return record.regions[0]["class"] == "scissors"},
		{"name": "set track ID", "script": scripts.track, "args": [0, _record(), "box-1", "T99"], "check": func(record): return record.regions[0].track_id == "T99"},
		{"name": "clear track ID", "script": scripts.track, "args": [0, _record(), "box-1", null], "check": func(record): return record.regions[0].track_id == null},
		{"name": "toggle fill", "script": scripts.fill, "args": [0, _record(), "box-1"], "check": func(record): return record.regions[0].filled == true},
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


static func _store():
	var store = load(STORE_PATH).new()
	store.load_model_records([_record()])
	return store


static func _history(capacity: int = 200):
	return load(HISTORY_PATH).new(capacity)


static func _record() -> Dictionary:
	return {
		"schema_version": 1,
		"dataset_id": "edit-tests",
		"source": "model_output_v1",
		"frame": 0,
		"image_size": [100, 80],
		"regions": [
			{"id": "box-1", "class": "grasper", "kind": "instrument", "box": [10, 10, 20, 15], "conf": 0.9, "track_id": "T01", "filled": false},
			{"id": "poly-1", "class": "gallbladder", "kind": "anatomy", "polygon": [[40, 40], [55, 40], [45, 55]], "filled": true},
		],
	}
