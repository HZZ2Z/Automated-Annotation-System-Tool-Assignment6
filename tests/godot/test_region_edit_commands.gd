extends RefCounted


const STORE := preload("res://client/domain/annotation_store.gd")
const HISTORY := preload("res://client/domain/command_history.gd")
const ADD_POLYGON := preload("res://client/domain/commands/add_polygon_command.gd")
const REPLACE_GEOMETRY := preload("res://client/domain/commands/replace_region_geometry_command.gd")
const RELABEL := preload("res://client/domain/commands/relabel_region_command.gd")


static func run(support: TestSupport) -> void:
	_test_add_polygon_round_trip(support)
	_test_replace_geometry_round_trip(support)
	_test_invalid_geometry_is_atomic(support)
	_test_polygon_image_bounds_are_atomic_and_round_trip(support)
	_test_relabel_class_kind_pair_round_trip(support)
	_test_relabel_blank_inputs_are_atomic(support)
	_test_relabel_class_only_compatibility(support)


static func _test_add_polygon_round_trip(support: TestSupport) -> void:
	var store = _store()
	var history = HISTORY.new(200)
	var before: Dictionary = store.get_corrected_record(0)
	var command = ADD_POLYGON.new(
		0,
		before,
		[[70, 60], [88, 62], [82, 79], [68, 75]],
		"scissors",
		"instrument",
		Vector2(100, 80),
	)
	var expected: Dictionary = {
		"schema_version": 1,
		"source": "sample_v1",
		"frame": 0,
		"regions": [
			{"id": "box-1", "class": "grasper", "kind": "instrument", "box": [10, 10, 20, 15], "conf": 0.9, "track_id": "T01"},
			{"id": "poly-1", "class": "gallbladder", "kind": "anatomy", "polygon": [[40, 40], [55, 40], [45, 55]]},
			{
				"id": command.get_region_id(),
				"class": "scissors",
				"kind": "instrument",
				"polygon": [[70.0, 60.0], [88.0, 62.0], [82.0, 79.0], [68.0, 75.0]],
				"track_id": null,
			},
		],
	}.duplicate(true)
	var errors: PackedStringArray = history.execute(command, store)
	support.expect(errors.is_empty(), "valid polygon creation should apply")
	support.expect_equal(history.get_undo_count(), 1, "polygon creation should be one undoable edit")
	support.expect_equal(history.get_redo_count(), 0, "bounded polygon creation should start without a redo entry")
	support.expect_equal(store.get_corrected_record(0), expected, "bounded polygon creation should produce the exact literal expected record")
	support.expect(history.undo(store), "polygon creation should undo")
	support.expect_equal(store.get_corrected_record(0), before, "polygon creation undo should restore exact frame snapshot")
	support.expect_equal(history.get_undo_count(), 0, "bounded polygon creation undo should consume its undo entry")
	support.expect_equal(history.get_redo_count(), 1, "bounded polygon creation undo should create one redo entry")
	support.expect(history.redo(store).is_empty(), "polygon creation should redo")
	support.expect_equal(store.get_corrected_record(0), expected, "polygon creation redo should restore the exact literal expected record")
	support.expect_equal(history.get_undo_count(), 1, "bounded polygon creation redo should restore one undo entry")
	support.expect_equal(history.get_redo_count(), 0, "bounded polygon creation redo should consume its redo entry")


static func _test_replace_geometry_round_trip(support: TestSupport) -> void:
	var store = _store()
	var history = HISTORY.new(200)
	var before: Dictionary = store.get_corrected_record(0)
	var replacement := [[12, 11], [31, 12], [28, 26], [13, 24]]
	var command = REPLACE_GEOMETRY.new(0, before, "box-1", replacement)
	var errors: PackedStringArray = history.execute(command, store)
	support.expect(errors.is_empty(), "valid polygon replacement should apply")
	var after: Dictionary = store.get_corrected_record(0)
	var region: Dictionary = after.regions[0]
	support.expect_equal(region.polygon, [[12.0, 11.0], [31.0, 12.0], [28.0, 26.0], [13.0, 24.0]], "geometry replacement should install the polygon")
	support.expect(not region.has("box"), "geometry replacement should remove stale fallback box geometry")
	support.expect_equal(region["class"], "grasper", "geometry replacement should preserve class")
	support.expect_equal(region.kind, "instrument", "geometry replacement should preserve kind")
	support.expect_equal(region.conf, 0.9, "geometry replacement should preserve confidence")
	support.expect_equal(region.track_id, "T01", "geometry replacement should preserve track ID")
	support.expect_equal(history.get_undo_count(), 1, "geometry replacement should be one undoable edit")
	support.expect(history.undo(store), "geometry replacement should undo")
	support.expect_equal(store.get_corrected_record(0), before, "geometry replacement undo should restore exact frame snapshot")
	support.expect(history.redo(store).is_empty(), "geometry replacement should redo")
	support.expect_equal(store.get_corrected_record(0), after, "geometry replacement redo should restore exact result")


static func _test_invalid_geometry_is_atomic(support: TestSupport) -> void:
	for invalid: Variant in [[], [[1, 1], [2, 2]], [[1, 1], [5, 5], [1, 5], [5, 1]], [[1, 1], [NAN, 3], [4, 5]]]:
		var store = _store()
		var history = HISTORY.new(200)
		var before: Dictionary = store.get_corrected_record(0)
		var command = REPLACE_GEOMETRY.new(0, before, "box-1", invalid)
		var errors: PackedStringArray = history.execute(command, store)
		support.expect(not errors.is_empty(), "invalid polygon replacement should be refused with an error")
		support.expect_equal(store.get_corrected_record(0), before, "invalid polygon replacement should preserve corrected state")
		support.expect_equal(history.get_undo_count(), 0, "invalid polygon replacement should not enter history")


static func _test_polygon_image_bounds_are_atomic_and_round_trip(support: TestSupport) -> void:
	var image_size := Vector2(100, 80)
	var before := _record()
	var cases := [
		{
			"name": "polygon add",
			"command": ADD_POLYGON.new(0, before, [[90, 70], [101, 70], [95, 79]], "unknown", "region", image_size),
		},
		{
			"name": "polygon resize",
			"command": REPLACE_GEOMETRY.new(0, before, "poly-1", [[40, 40], [101, 40], [45, 55]], image_size),
		},
	]
	for case: Dictionary in cases:
		var store = _store()
		var history = HISTORY.new(200)
		var store_before: Dictionary = store.get_corrected_record(0)
		var errors: PackedStringArray = history.execute(case.command, store)
		support.expect(not errors.is_empty(), "%s beyond the image must explain refusal" % case.name)
		support.expect_equal(case.command.after, case.command.before, "%s refusal should restore the retained after snapshot" % case.name)
		support.expect_equal(store.get_corrected_record(0), store_before, "%s refusal must preserve corrected state" % case.name)
		support.expect_equal(history.get_undo_count(), 0, "%s refusal must not enter history" % case.name)

	var store = _store()
	var history = HISTORY.new(200)
	var valid_before: Dictionary = store.get_corrected_record(0)
	var command = REPLACE_GEOMETRY.new(
		0,
		valid_before,
		"poly-1",
		[[40, 40], [100, 40], [45, 80]],
		image_size,
	)
	support.expect(history.execute(command, store).is_empty(), "polygon resize ending exactly on image edges should apply")
	var valid_after: Dictionary = store.get_corrected_record(0)
	support.expect(history.undo(store), "bounded polygon resize should undo")
	support.expect_equal(store.get_corrected_record(0), valid_before, "bounded polygon resize undo should restore exact geometry")
	support.expect(history.redo(store).is_empty(), "bounded polygon resize should redo")
	support.expect_equal(store.get_corrected_record(0), valid_after, "bounded polygon resize redo should restore exact geometry")


static func _test_relabel_class_kind_pair_round_trip(support: TestSupport) -> void:
	var store = _store()
	var history = HISTORY.new(200)
	var before: Dictionary = store.get_corrected_record(0)
	var command = RELABEL.new(0, before, "box-1", "  lesion  ", "  pathology custom  ")
	support.expect_equal(history.execute(command, store), PackedStringArray(), "free-form class and kind should be accepted")
	var changed: Dictionary = store.get_corrected_record(0).regions[0]
	support.expect_equal([changed["class"], changed["kind"]], ["lesion", "pathology custom"], "one command should trim and update both fields")
	support.expect_equal(history.get_undo_count(), 1, "class and kind should create exactly one history command")
	support.expect(history.undo(store), "class and kind change should be undoable")
	support.expect_equal(store.get_corrected_record(0), before, "undo should restore the exact prior record")
	support.expect(history.redo(store).is_empty(), "class and kind change should be redoable")
	support.expect_equal(store.get_corrected_record(0).regions[0], changed, "redo should restore the exact pair")


static func _test_relabel_blank_inputs_are_atomic(support: TestSupport) -> void:
	for values: Array in [["   ", "custom"], ["lesion", "   "]]:
		var store = _store()
		var history = HISTORY.new(200)
		var before: Dictionary = store.get_corrected_record(0)
		var command = RELABEL.new(0, before, "box-1", values[0], values[1])
		var errors: PackedStringArray = history.execute(command, store)
		support.expect(not errors.is_empty(), "blank class or kind should be refused")
		support.expect_equal(store.get_corrected_record(0), before, "blank class or kind refusal should preserve Store exactly")
		support.expect_equal(history.get_undo_count(), 0, "blank class or kind refusal should not enter history")
		support.expect_equal(history.get_redo_count(), 0, "blank class or kind refusal should not alter redo history")


static func _test_relabel_class_only_compatibility(support: TestSupport) -> void:
	var store = _store()
	var history = HISTORY.new(200)
	var before: Dictionary = store.get_corrected_record(0)
	var taxonomy_command = RELABEL.new(0, before, "box-1", "  scissors  ")
	support.expect(history.execute(taxonomy_command, store).is_empty(), "old class-only callers should remain supported")
	var taxonomy_region: Dictionary = store.get_corrected_record(0).regions[0]
	support.expect_equal(taxonomy_region["class"], "scissors", "class-only caller should trim class")
	support.expect_equal(taxonomy_region["kind"], "instrument", "known class should still derive taxonomy kind")

	var unknown_store = _store()
	var unknown_history = HISTORY.new(200)
	var unknown_before: Dictionary = unknown_store.get_corrected_record(0)
	var unknown_command = RELABEL.new(0, unknown_before, "box-1", "custom_label")
	support.expect(unknown_history.execute(unknown_command, unknown_store).is_empty(), "unknown class-only caller should remain supported")
	support.expect_equal(unknown_store.get_corrected_record(0).regions[0]["kind"], "instrument", "unknown class should retain the original valid kind")


static func _store():
	var store = STORE.new()
	store.load_model_records([_record()])
	return store


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
