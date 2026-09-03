extends RefCounted


const EDIT_PLUGIN := preload("res://client/plugins/edit/basic_edit_tools/plugin.gd")
const STORE_SCRIPT := preload("res://client/domain/annotation_store.gd")
const HISTORY_SCRIPT := preload("res://client/domain/command_history.gd")


class ViewportStub extends RefCounted:
	func set_record(_record: Dictionary) -> void: pass
	func set_selected_region_id(_region_id: String) -> void: pass
	func get_image_transform() -> Variant: return null


static func run(support) -> void:
	var store = STORE_SCRIPT.new()
	support.expect_equal(store.load_model_records(_records()), PackedStringArray(), "range fixture should load")
	var history = HISTORY_SCRIPT.new()
	var plugin = EDIT_PLUGIN.new()
	var selected := [""]
	var context := {
		"store": store,
		"history": history,
		"viewport": ViewportStub.new(),
		"current_frame": func(): return 0,
		"selected_region": func(): return selected[0],
		"set_selected_region": func(value: String): selected[0] = value,
		"status": func(_message: String): pass,
		"taxonomy": {"classes": [{"id": "grasper", "kind": "instrument"}]},
	}
	support.expect_equal(plugin.activate(context), PackedStringArray(), "range-capable Edit plugin should activate")

	var errors: PackedStringArray = plugin.invoke(&"range_propagate", {
		"keyframe": 0,
		"start_frame": 1,
		"end_frame": 2,
		"mode": "overwrite",
	})
	support.expect_equal(errors, PackedStringArray(), "overwrite propagation should succeed")
	support.expect_equal(history.get_undo_count(), 1, "one propagated range should be one undoable action")
	for frame in [1, 2]:
		var target: Dictionary = store.get_corrected_record(frame)
		support.expect_equal(target.source, "camera_%d" % frame, "propagation must preserve target source identity")
		support.expect_equal(target.time_s, float(frame) * 0.1, "propagation must preserve target timestamp")
		support.expect_equal(target.regions, store.get_corrected_record(0).regions, "overwrite should deep-copy keyframe regions")
	var operations: Array = store.snapshot_batch_operations() if store.has_method("snapshot_batch_operations") else []
	support.expect_equal(operations.size(), 1, "range provenance should be stored separately from model-output records")
	if operations.size() == 1:
		support.expect_equal(operations[0].get("type"), "range_propagate", "range marker should identify the operation")
		support.expect_equal(operations[0].get("affected_frames"), [1, 2], "range marker should list committed targets")
	support.expect(not store.snapshot_corrected()[1].has("batch_operation"), "range provenance must not contaminate Model Output V1")

	support.expect(history.undo(store), "range propagation should undo")
	support.expect_equal(store.get_corrected_record(1).regions[1].id, "keep-1", "undo should restore every target frame")
	operations = store.snapshot_batch_operations() if store.has_method("snapshot_batch_operations") else []
	support.expect(operations.is_empty(), "undo should restore separate range provenance")
	support.expect_equal(history.redo(store), PackedStringArray(), "range propagation should redo")
	support.expect_equal(store.get_corrected_record(2).regions.size(), 1, "redo should reapply the whole range")
	support.expect(history.undo(store), "overwrite should return to the merge fixture")
	errors = plugin.invoke(&"range_propagate", {"keyframe": 0, "start_frame": 1, "end_frame": 1, "mode": "merge"})
	support.expect_equal(errors, PackedStringArray(), "merge propagation should succeed")
	var merged: Dictionary = store.get_corrected_record(1)
	support.expect_equal(merged.regions.size(), 2, "merge should retain unrelated target regions")
	support.expect_equal(merged.regions[0].class, "grasper", "merge should replace matching IDs from the keyframe")
	support.expect_equal(merged.regions[1].id, "keep-1", "merge should retain target-only IDs")

	var before: Array = store.snapshot_corrected()
	var undo_before: int = history.get_undo_count()
	errors = plugin.invoke(&"range_propagate", {"keyframe": 0, "start_frame": 1, "end_frame": 99, "mode": "merge"})
	support.expect(not errors.is_empty(), "out-of-range propagation should be rejected")
	support.expect_equal(store.snapshot_corrected(), before, "invalid propagation must be failure-atomic")
	support.expect_equal(history.get_undo_count(), undo_before, "invalid propagation must not enter history")


static func _records() -> Array:
	var result := []
	for frame in range(3):
		var regions := [
			{"id": "shared", "class": "grasper" if frame == 0 else "wrong", "kind": "instrument", "box": [10 + frame, 10, 20, 15]},
		]
		if frame > 0:
			regions.append({"id": "keep-%d" % frame, "class": "anatomy", "kind": "anatomy", "box": [40, 20, 10, 10]})
		result.append({
			"schema_version": 1,
			"source": "camera_%d" % frame,
			"frame": frame,
			"time_s": float(frame) * 0.1,
			"regions": regions,
		})
	return result
