extends RefCounted


const PROJECT_CLASS_CATALOG := preload("res://client/domain/project_class_catalog.gd")
const CLASS_COLOR_RESOLVER := preload("res://client/domain/class_color_resolver.gd")


static func run(support) -> void:
	_test_project_union_and_frame_rows(support)
	_test_incremental_sync_removes_zero_totals(support)
	_test_session_history_and_ordered_suggestions(support)
	_test_malformed_metadata_is_transactional(support)
	_test_logical_integer_frame_contract(support)
	_test_sync_observation_overrides_higher_frame_kind(support)


static func _test_project_union_and_frame_rows(support) -> void:
	var catalog = PROJECT_CLASS_CATALOG.new()
	var records := [_frame(0, [
		_box("a", "grasper", "instrument"),
		_box("b", "grasper", "assistant_tool"),
	]), _frame(1, [
		_hybrid("c", "gallbladder", "anatomy"),
	])]
	support.expect_equal(catalog.rebuild(records), PackedStringArray(), "valid metadata should index")
	var resolver = _resolver()
	var project_rows: Array[Dictionary] = catalog.project_rows(records[0], resolver)
	support.expect_equal(_project_counts(project_rows), {"gallbladder": 0, "grasper": 2},
		"project union and current-frame counts must be independent")
	var frame_rows: Array[Dictionary] = catalog.frame_rows(records[0], resolver)
	support.expect_equal(frame_rows.size(), 2, "current rows should contain one row per region")
	support.expect_equal(frame_rows[0].get("region_id"), "a", "frame rows should retain region IDs")
	support.expect_equal(frame_rows[1].get("kind"), "assistant_tool",
		"current rows must retain each region's free-form kind")
	support.expect_equal(frame_rows[0].get("geometry"), &"box",
		"box regions should report canonical box geometry")
	support.expect_equal(catalog.frame_rows(records[1], resolver)[0].get("geometry"), &"polygon",
		"polygon-first hybrid regions should report polygon geometry")
	support.expect(frame_rows[0].get("color").is_equal_approx(resolver.color_for("grasper")),
		"frame rows should use the shared class color resolver")


static func _test_incremental_sync_removes_zero_totals(support) -> void:
	var catalog = PROJECT_CLASS_CATALOG.new()
	var records := [_frame(0, [_box("a", "grasper", "instrument")]),
		_frame(1, [_box("b", "gallbladder", "anatomy")])]
	catalog.rebuild(records)
	var changed := _frame(0, [_box("b", "scissors", "custom_kind")])
	support.expect_equal(catalog.sync_record(changed), PackedStringArray(), "one frame should resync")
	support.expect_equal(_project_classes(catalog.project_rows(changed, _resolver())),
		["gallbladder", "scissors"], "classes with zero project objects must disappear")
	support.expect_equal(catalog.project_rows(changed, _resolver())[1].get("current_count"), 1,
		"resynced frame counts should replace the prior frame counts")


static func _test_session_history_and_ordered_suggestions(support) -> void:
	var catalog = PROJECT_CLASS_CATALOG.new()
	catalog.rebuild([_frame(0, [_box("a", "grasper", "instrument")])])
	catalog.remember(" custom class ", " free form ")
	catalog.remember("grasper", "instrument")
	catalog.sync_record(_frame(0, []))
	var suggestions: Array[Dictionary] = catalog.suggestions(_resolver())
	support.expect_equal(suggestions[0].get("class"), "grasper", "last confirmed pair should be suggested first")
	support.expect_equal(suggestions[0].get("kind"), "instrument", "suggestions should preserve the confirmed kind")
	support.expect(_has_pair(suggestions, "custom class", "free form"),
		"session history must preserve normalized free-form pairs")
	support.expect(_has_pair(suggestions, "grasper", "instrument"),
		"session history must survive last-object removal")
	support.expect_equal(catalog.last_pair(), {"class": "grasper", "kind": "instrument"},
		"last_pair should expose the latest confirmed pair")
	catalog.reset()
	support.expect_equal(catalog.suggestions(_resolver()), [], "source reset must clear session history")
	support.expect_equal(catalog.last_pair(), {}, "source reset must clear the last pair")


static func _test_malformed_metadata_is_transactional(support) -> void:
	var catalog = PROJECT_CLASS_CATALOG.new()
	var valid := [_frame(0, [_box("a", "grasper", "instrument")])]
	catalog.rebuild(valid)
	var before := catalog.project_rows(valid[0], _resolver())
	var malformed := [_frame(0, [_box("a", "grasper", "instrument")]), _frame(-1, [])]
	var errors: PackedStringArray = catalog.rebuild(malformed)
	support.expect(not errors.is_empty(), "negative frame metadata should be rejected")
	support.expect_equal(catalog.project_rows(valid[0], _resolver()), before,
		"failed rebuild must preserve the previously valid catalog")
	var malformed_region := _frame(0, [_box("a", "", "instrument")])
	errors = catalog.sync_record(malformed_region)
	support.expect(not errors.is_empty(), "empty class metadata should be rejected")
	support.expect_equal(catalog.project_rows(valid[0], _resolver()), before,
		"failed frame sync must preserve the prior frame snapshot")


static func _test_logical_integer_frame_contract(support) -> void:
	var catalog = PROJECT_CLASS_CATALOG.new()
	support.expect_equal(catalog.rebuild([_frame(0.0, [_box("a", "grasper", "instrument")])]),
		PackedStringArray(), "rebuild should accept finite non-negative integral float frames")
	support.expect_equal(catalog.sync_record(_frame(0.0, [_box("a", "grasper", "updated_kind")])),
		PackedStringArray(), "sync should accept finite non-negative integral float frames")
	var before := catalog.project_rows(_frame(0, []), _resolver())
	support.expect(not catalog.rebuild([_frame(1.5, [])]).is_empty(),
		"rebuild should reject fractional frame values")
	support.expect_equal(catalog.project_rows(_frame(0, []), _resolver()), before,
		"fractional rebuild refusal should preserve the valid catalog")
	support.expect(not catalog.sync_record(_frame(-1.0, [])).is_empty(),
		"sync should reject negative integral float frames")


static func _test_sync_observation_overrides_higher_frame_kind(support) -> void:
	var catalog = PROJECT_CLASS_CATALOG.new()
	var records := [
		_frame(1, [_box("low", "grasper", "low_kind")]),
		_frame(5, [_box("high", "grasper", "high_kind")]),
	]
	support.expect_equal(catalog.rebuild(records), PackedStringArray(), "ordered frames should index")
	support.expect_equal(catalog.sync_record(_frame(1, [_box("low", "grasper", "new_low_kind")])),
		PackedStringArray(), "low-frame replacement should index")
	support.expect_equal(_suggestion_kind(catalog.suggestions(_resolver()), "grasper"), "new_low_kind",
		"the successful replacement should be the latest kind observation even below an older high frame")


static func _frame(frame: Variant, regions: Array) -> Dictionary:
	return {"frame": frame, "regions": regions}


static func _box(region_id: String, class_label: String, kind: String) -> Dictionary:
	return {
		"id": region_id,
		"class": class_label,
		"kind": kind,
		"box": [1, 2, 30, 40],
	}


static func _polygon(region_id: String, class_label: String, kind: String) -> Dictionary:
	return {
		"id": region_id,
		"class": class_label,
		"kind": kind,
		"polygon": [[1, 2], [31, 2], [31, 42], [1, 42]],
	}


static func _hybrid(region_id: String, class_label: String, kind: String) -> Dictionary:
	var region := _polygon(region_id, class_label, kind)
	region["box"] = [1, 2, 30, 40]
	return region


static func _resolver():
	return CLASS_COLOR_RESOLVER.new({"classes": [{"id": "grasper", "color": "#ef4444"}]})


static func _project_counts(rows: Array[Dictionary]) -> Dictionary:
	var result := {}
	for row: Dictionary in rows:
		result[row["class"]] = row["current_count"]
	return result


static func _project_classes(rows: Array[Dictionary]) -> Array:
	var result: Array = []
	for row: Dictionary in rows:
		result.append(row["class"])
	return result


static func _has_pair(rows: Array[Dictionary], class_label: String, kind: String) -> bool:
	for row: Dictionary in rows:
		if row.get("class") == class_label and row.get("kind") == kind:
			return true
	return false


static func _suggestion_kind(rows: Array[Dictionary], class_label: String) -> String:
	for row: Dictionary in rows:
		if row.get("class") == class_label:
			return row.get("kind", "")
	return ""
