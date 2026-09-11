extends SceneTree

const SUPPORT := preload("res://tests/godot/test_support.gd")
const STORE := preload("res://client/domain/annotation_store.gd")
const HISTORY := preload("res://client/domain/command_history.gd")
const RELABEL := preload("res://client/domain/commands/relabel_region_command.gd")
const GEOMETRY := preload("res://client/domain/region_geometry.gd")
const SOLVER_PATH := "res://client/domain/region_match_solver.gd"
const COMMAND_PATH := "res://client/domain/commands/match_region_command.gd"
const IMAGE_SIZE := Vector2(120, 90)

var support = SUPPORT.new()
var solver: GDScript
var command_script: GDScript


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	support.expect(ResourceLoader.exists(SOLVER_PATH), "Match must provide a geometry/label solver")
	support.expect(ResourceLoader.exists(COMMAND_PATH), "Match must provide one reversible command")
	if support.failures.is_empty():
		solver = load(SOLVER_PATH)
		command_script = load(COMMAND_PATH)
		_test_exact_merges()
		_test_gap_limit_and_locality()
		_test_fallbacks_preserve_geometry()
		_test_label_copy_and_invalid_targets()
		_test_atomic_history_and_export()
		_test_noop_and_stale_commands()
	if support.failures.is_empty():
		print("PASS: Match geometry, labels and atomic history")
		quit(0)
	else:
		push_error(support.failure_report())
		quit(1)


func _test_exact_merges() -> void:
	for entry: Dictionary in [
		{"a": [10, 10, 4, 4], "b": [14, 10, 10, 10], "area": 116.0, "name": "shared edge"},
		{"a": [10, 10, 6, 6], "b": [14, 10, 10, 10], "area": 124.0, "name": "overlap"},
		{"a": [12, 12, 2, 2], "b": [10, 10, 10, 10], "area": 100.0, "name": "contained defect"},
		{"a": [10, 10, 10, 10], "b": [12, 12, 2, 2], "area": 100.0, "name": "contained reference"},
	]:
		var before := _record(entry.a, entry.b)
		var original := before.duplicate(true)
		var result: Dictionary = solver.solve(before, "a", "b", IMAGE_SIZE)
		support.expect_equal(result.status, &"merged", "%s should merge" % entry.name)
		support.expect_equal(before, original, "solver must not mutate its input")
		if result.status != &"merged":
			continue
		support.expect_equal(result.record.regions.size(), 1, "a merge removes only A")
		var b: Dictionary = result.record.regions[0]
		support.expect_equal([b.id, b["class"], b.kind, b.conf, b.track_id],
			["b", "gallbladder", "anatomy", 0.8, "B-track"], "reference identity and metadata survive")
		support.expect(not b.has("box"), "merged geometry must not retain a stale box")
		support.expect(absf(_area(b.polygon) - entry.area) < 0.0001, "%s has its exact union area" % entry.name)
		# 输入 polygon 的绕向不能改变结果，也不能让旧 box 覆盖真实轮廓。
		before.regions[0]["polygon"] = _box_points(entry.a)
		before.regions[0].polygon.reverse()
		before.regions[0].box = [80, 60, 2, 2]
		result = solver.solve(before, "a", "b", IMAGE_SIZE)
		support.expect_equal(result.status, &"merged", "polygon takes precedence over a legacy box")
		if result.status == &"merged":
			support.expect(absf(_area(result.record.regions[0].polygon) - entry.area) < 0.0001,
				"reversed winding preserves the actual union")


func _test_gap_limit_and_locality() -> void:
	for gap: float in [0.5, 1.0, 1.01]:
		var before := _record([10, 10, 4, 4], [14 + gap, 10, 10, 10])
		var result: Dictionary = solver.solve(before, "a", "b", IMAGE_SIZE)
		support.expect_equal(result.status, &"merged" if gap <= 1.0 else &"relabeled",
			"gap %.2f uses the one IMAGE pixel limit" % gap)
		if gap <= 1.0 and result.status == &"merged":
			var region: Dictionary = result.record.regions[0]
			var area := _area(region.polygon)
			support.expect(area > 116.0 and area < 118.0, "only a local one-pixel-wide bridge is added")
			support.expect(GEOMETRY.contains(region, Vector2(10.1, 13.9)), "bridge retains the far A corner")
			support.expect(GEOMETRY.contains(region, Vector2(23 + gap, 19)), "bridge retains the far B corner")
			support.expect(not GEOMETRY.contains(region, Vector2(11, 18)), "bridge cannot fill the combined bounding box")
	var diagonal: Dictionary = solver.solve(_record([10, 10, 4, 4], [15, 15, 4, 4]), "a", "b", IMAGE_SIZE)
	support.expect_equal(diagonal.status, &"relabeled", "diagonal distance uses Euclidean geometry, not a square dilation")
	var edge: Dictionary = solver.solve(_record([10, 0, 4, 4], [15, 0, 4, 4]), "a", "b", IMAGE_SIZE)
	support.expect_equal(edge.status, &"merged", "a bridge at the image boundary is clipped safely")
	if edge.status == &"merged":
		support.expect(GEOMETRY.fits_image(edge.record.regions[0], IMAGE_SIZE), "bridge cannot extend outside the image")
	var corner: Dictionary = solver.solve(_record([10, 10, 4, 4], [14, 14, 4, 4]), "a", "b", IMAGE_SIZE)
	support.expect_equal(corner.status, &"relabeled", "point contact with unsupported union topology keeps separate regions")


func _test_fallbacks_preserve_geometry() -> void:
	var holed := _record([10, 10, 20, 20], [26, 10, 4, 20])
	holed.regions[0].erase("box")
	holed.regions[0]["polygon"] = [[10, 10], [30, 10], [30, 14], [14, 14], [14, 26], [30, 26], [30, 30], [10, 30]]
	_expect_relabel_only(holed, "a holed union must retain both original geometries")
	var invalid := _record()
	invalid.regions[0].erase("box")
	invalid.regions[0]["polygon"] = [[10, 10], [14, 14], [10, 14], [14, 10]]
	_expect_relabel_only(invalid, "an invalid model contour can still have its labels corrected")
	var blocked := _record([10, 10, 4, 4], [15, 10, 10, 10])
	blocked.regions.append({"id": "c", "class": "artery", "kind": "anatomy", "box": [14.1, 9.8, 0.8, 0.4]})
	_expect_relabel_only(blocked, "a bridge cannot consume a third region")
	var unblocked := _record([10, 10, 4, 4], [15, 10, 10, 10])
	unblocked.regions.append({"id": "c", "class": "artery", "kind": "anatomy", "box": [11, 11, 1, 1]})
	var result: Dictionary = solver.solve(unblocked, "a", "b", IMAGE_SIZE)
	support.expect_equal(result.status, &"merged", "pre-existing overlap with a third region does not forbid a safe bridge")
	support.expect_equal(result.record.regions[-1], unblocked.regions[-1], "unrelated regions remain byte-for-byte equal")


func _test_label_copy_and_invalid_targets() -> void:
	var before := _record()
	before.regions[1]["class"] = " custom class "
	before.regions[1].kind = " custom kind "
	_expect_relabel_only(before, "both labels are copied verbatim, without taxonomy inference")
	for ids: Array in [["a", "missing"], ["missing", "b"], ["a", "a"]]:
		var result: Dictionary = solver.solve(before, ids[0], ids[1], IMAGE_SIZE)
		support.expect_equal(result.status, &"invalid", "missing or identical IDs cannot make a correction")
		support.expect_equal(result.record, before, "invalid selection does not change a record")


func _test_atomic_history_and_export() -> void:
	var before := _record([10, 10, 4, 4], [14, 10, 10, 10])
	var other := _record()
	other.frame = 8
	other.time_s = 1.0
	var store = STORE.new()
	var history = HISTORY.new()
	support.expect_equal(store.load_model_records([before, other]), PackedStringArray(), "history fixture loads")
	var command = command_script.new(7, before, "a", "b", IMAGE_SIZE)
	support.expect_equal(history.execute(command, store), PackedStringArray(), "Match commits through real Store validation")
	var after: Dictionary = store.get_corrected_record(7)
	support.expect_equal(after.regions.size(), 1, "the complete edit commits together")
	support.expect_equal(history.get_undo_count(), 1, "relabel, union and deletion consume one undo entry")
	support.expect_equal(store.get_corrected_record(8), other, "a Match edit never reaches another frame")
	support.expect_equal(store.get_model_record(7), before, "the immutable model baseline survives correction")
	support.expect_equal(history.try_undo(store), PackedStringArray(), "one undo succeeds")
	support.expect_equal(store.get_corrected_record(7), before, "one undo restores both original regions and every field")
	support.expect_equal(history.redo(store), PackedStringArray(), "one redo succeeds")
	support.expect_equal(store.get_corrected_record(7), after, "redo reuses the exact saved result")
	var reopened = STORE.new()
	var serialized: Variant = JSON.parse_string(JSON.stringify([after, other]))
	support.expect_equal(reopened.load_model_records(serialized), PackedStringArray(), "corrected V1 data survives JSON save/reopen")
	var expected_reopened := after.duplicate(true)
	expected_reopened.frame = 7.0
	expected_reopened.schema_version = 1.0
	support.expect_equal(reopened.get_corrected_record(7), expected_reopened,
		"save/reopen preserves the complete merged record across JSON numeric types")


func _test_noop_and_stale_commands() -> void:
	var before := _record()
	before.regions[0]["class"] = "gallbladder"
	before.regions[0].kind = "anatomy"
	var store = STORE.new()
	var history = HISTORY.new()
	store.load_model_records([before])
	history.execute(RELABEL.new(7, before, "a", "temporary", "other"), store)
	history.try_undo(store)
	var revision: int = store.current_revision()
	support.expect_equal(history.execute(command_script.new(7, before, "a", "b", IMAGE_SIZE), store),
		PackedStringArray(), "identical labels on separated regions are a successful no-op")
	support.expect_equal([history.get_undo_count(), history.get_redo_count(), store.current_revision()], [0, 1, revision],
		"a no-op preserves redo and does not dirty Store again")
	var stale = command_script.new(7, before, "a", "b", IMAGE_SIZE)
	var changed := before.duplicate(true)
	changed.regions[0]["class"] = "newer-edit"
	store.replace_corrected_record(7, changed)
	support.expect(not stale.apply(store).is_empty(), "a stale snapshot is rejected even for a formerly no-op command")
	support.expect_equal(store.get_corrected_record(7), changed, "stale command cannot overwrite a newer edit")
	var same_labels_touch := _record([10, 10, 4, 4], [14, 10, 10, 10])
	same_labels_touch.regions[0]["class"] = "gallbladder"
	same_labels_touch.regions[0].kind = "anatomy"
	support.expect_equal(solver.solve(same_labels_touch, "a", "b", IMAGE_SIZE).status, &"merged",
		"identical labels must not skip the adjacency merge")


func _expect_relabel_only(before: Dictionary, message: String) -> void:
	var expected := before.duplicate(true)
	expected.regions[0]["class"] = before.regions[1]["class"]
	expected.regions[0].kind = before.regions[1].kind
	var result: Dictionary = solver.solve(before, "a", "b", IMAGE_SIZE)
	support.expect_equal(result.status, &"relabeled", message)
	support.expect_equal(result.record, expected, "fallback changes exactly A.class and A.kind")
	support.expect(not String(result.message).is_empty(), "fallback explains why the regions stayed separate")


func _record(a: Array = [10, 10, 4, 4], b: Array = [60, 10, 10, 10]) -> Dictionary:
	return {"schema_version": 1, "source": "match.png", "frame": 7, "time_s": 0.0, "regions": [
		{"id": "a", "class": "grasper", "kind": "instrument", "box": a.duplicate(), "conf": 0.2, "track_id": "A-track"},
		{"id": "b", "class": "gallbladder", "kind": "anatomy", "box": b.duplicate(), "conf": 0.8, "track_id": "B-track"},
	]}


func _box_points(box: Array) -> Array:
	return [[box[0], box[1]], [box[0] + box[2], box[1]], [box[0] + box[2], box[1] + box[3]], [box[0], box[1] + box[3]]]


func _area(points: Array) -> float:
	var twice := 0.0
	for index in range(points.size()):
		var a: Array = points[index]
		var b: Array = points[(index + 1) % points.size()]
		twice += a[0] * b[1] - a[1] * b[0]
	return absf(twice) * 0.5
